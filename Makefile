.PHONY: up down logs ps psql carga reset carga-sngpc carga-incremental test-idempotencia test-idempotencia-dimensoes simular-atraso reprocessar-janela lakehouse lakehouse-export lakehouse-compact lakehouse-validate lakehouse-bench modelo-dimensional test-scd2 otimizar-performance benchmark-performance checar-freshness test-freshness airflow-up airflow-demo airflow-down airflow-backfill airflow-falha airflow-sem-falha

# Sobe o banco + roda a carga (build implícito, detached)
up:
	docker compose up -d --build

down:
	docker compose down

# Apaga também o volume de dados (recarrega do zero)
reset:
	docker compose down -v

logs:
	docker compose logs -f

ps:
	docker compose ps

# Console psql dentro do container do banco
psql:
	docker compose exec db psql -U $${POSTGRES_USER:-postgres} -d $${POSTGRES_DB:-farmadata}

# Reexecuta só o serviço de carga (útil após mudar ANO_RECORTE)
carga:
	docker compose up carga

# Camada analítica (Delta Lake/Parquet) — ver docs/CAMADA_ANALITICA.md
LAKE = docker compose --profile lakehouse run --rm lakehouse

lakehouse:
	$(LAKE)

lakehouse-export:
	$(LAKE) python exportar_delta.py

lakehouse-compact:
	$(LAKE) python compactar_delta.py

lakehouse-validate:
	$(LAKE) python validar_duckdb.py

lakehouse-bench:
	$(LAKE) python benchmark_layout.py

# Só a ingestão SNGPC. Ex.: make carga-sngpc MESES=202001,202002 FORCE=1
carga-sngpc:
	docker compose run --rm -e SNGPC_MESES=$(MESES) -e SNGPC_FORCE=$(FORCE) carga \
	  sh -c "npm install --omit=dev --silent pg-copy-streams && node scripts/carregar_sngpc.js"

# Carga incremental: processa apenas o que ainda não está em carga_arquivo
carga-incremental:
	docker compose run --rm carga \
	  sh -c "npm install --omit=dev --silent pg-copy-streams && node scripts/carregar_sngpc.js"

# Prova de idempotência (gera docs/evidencias/idempotencia.txt). Ex.: make test-idempotencia MES=202001
test-idempotencia:
	bash ./test_idempotencia.sh $(or $(MES),202001)

# CSV de fevereiro/2020 com venda de janeiro e venda fora do recorte.
# Evidência em docs/evidencias/dado_atrasado.txt. Não grava no banco farmadata.
simular-atraso:
	bash ./test_dado_atrasado.sh

# Janeiro já carregado; fevereiro traz uma venda de janeiro e é recarregado.
# Evidência em docs/evidencias/reprocessamento_janela.txt. Não grava no banco farmadata.
reprocessar-janela:
	bash ./test_reprocessar_janela.sh

# Modelo dimensional (ver docs/MODELO_DIMENSIONAL.md): sincroniza dim_municipio (SCD2)
# e recarrega fato_venda_medicamento. Requer municipio/venda_medicamento já carregados.
modelo-dimensional:
	docker compose exec -T db psql -U $${POSTGRES_USER:-postgres} -d $${POSTGRES_DB:-farmadata} -v ON_ERROR_STOP=1 -c \
	  "SELECT * FROM aplicar_scd2_municipio(); SELECT carregar_fato_venda_medicamento() AS linhas_carregadas;"

# Prova de versionamento SCD2 em dim_municipio (gera docs/evidencias/scd2.txt)
test-scd2:
	bash ./test_scd2_municipio.sh

# Otimização de performance da camada de consumo (issue #28). Reaplica sql/11 (idempotente:
# garante sk_* persistida em periodo/medicamento num banco criado antes da emenda ao ADR-004),
# cria os índices do sql/14 e atualiza o Visibility Map. Não rode durante uma carga
# (CREATE INDEX bloqueia escritas na fato).
otimizar-performance:
	docker compose exec -T db psql -U $${POSTGRES_USER:-postgres} -d $${POSTGRES_DB:-farmadata} -v ON_ERROR_STOP=1 -q < sql/11_dimensional_dim_municipio_scd.sql
	docker compose exec -T db psql -U $${POSTGRES_USER:-postgres} -d $${POSTGRES_DB:-farmadata} -v ON_ERROR_STOP=1 -q < sql/14_otimizacao_performance.sql
	docker compose exec -T db psql -U $${POSTGRES_USER:-postgres} -d $${POSTGRES_DB:-farmadata} -v ON_ERROR_STOP=1 -c "SET max_parallel_maintenance_workers = 0;" -c "VACUUM fato_venda_medicamento;"

# Reproduz planos de execução (docs/performance/explain_before.txt e explain_after.txt).
# O "antes" roda dentro de BEGIN ... ROLLBACK: o banco real não é alterado.
benchmark-performance:
	bash ./scripts/gerar_explain_performance.sh

# Freshness da tabela de consumo (padrão: fato_venda_medicamento). Ex.: make checar-freshness TABELA=fato_venda_medicamento
checar-freshness:
	bash ./scripts/checar_freshness.sh $(TABELA)

# Prova do atraso induzido (gera docs/evidencias/freshness.txt)
test-freshness:
	bash ./test_freshness.sh



# Orquestração (Airflow) — ver docs/orchestration/README.md
AIRFLOW = docker compose -f docker-compose.yml -f docker-compose.airflow.yml

airflow-up:
	$(AIRFLOW) up -d --build db airflow

# Demonstração com fixtures num banco de testes (farmadata_orquestracao), sem tocar no farmadata
airflow-demo:
	bash airflow/preparar_banco_demo.sh
	MSYS_NO_PATHCONV=1 FARMADATA_DB=farmadata_orquestracao FARMADATA_SNGPC_DIR=/opt/farmadata/scripts/fixtures/orquestracao \
	  $(AIRFLOW) up -d --build db airflow

airflow-down:
	$(AIRFLOW) stop airflow airflow-metadb

# Reprocessamento histórico. Ex.: make airflow-backfill INICIO=2020-01-01 FIM=2020-06-01 [EXTRA="--reset-dagruns -y"]
airflow-backfill:
	$(AIRFLOW) exec airflow airflow dags backfill farmadata_pipeline -s $(or $(INICIO),2020-01-01) -e $(or $(FIM),2020-06-01) $(EXTRA)

# Injeção de falha: verificar_fonte_sngpc falha nas N primeiras tentativas. Ex.: make airflow-falha FALHAS=2
airflow-falha:
	$(AIRFLOW) exec airflow airflow variables set farmadata_falha_injetada '{"task_id": "verificar_fonte_sngpc", "falhas": $(or $(FALHAS),2)}'

airflow-sem-falha:
	$(AIRFLOW) exec airflow airflow variables delete farmadata_falha_injetada
