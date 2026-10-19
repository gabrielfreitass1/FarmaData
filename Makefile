.PHONY: up down logs ps psql carga reset carga-sngpc carga-incremental test-idempotencia test-idempotencia-dimensoes simular-atraso reprocessar-janela lakehouse lakehouse-export lakehouse-compact lakehouse-validate lakehouse-bench

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


