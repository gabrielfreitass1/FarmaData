# Diário de bordo — Semanas 7 a 13

> Registro das decisões, bloqueios e responsáveis da Squad para as Entregas 2 e 3.
> Ritual nas semanas 7 a 10: reunião da Squad após as aulas de segunda e quarta de cada semana.
> Nas semanas 11 a 13 a coordenação foi feita pelo grupo do WhatsApp da Squad. Em todas as
> semanas, as decisões foram aplicadas direto no código/commit correspondente.

## Semana 7 — 22/09 a 28/09

Nos encontramos na segunda (22/09) e na quarta (24/09), logo depois da aula. Ruan modelou o
schema completo em sete etapas incrementais: geografia (UF/município), tempo, medicamento e
CID-10, conselho profissional e listas fixas da Anvisa, a tabela fato `venda_medicamento` com
seus índices, e por fim o Docker Compose com o README de reprodutibilidade completa. Junto
disso ele registrou a decisão de modelagem no ADR-001: insert-only normalizado, seguindo o
método de 6 passos da disciplina, e tornou o recorte de ano configurável via `ANO_RECORTE`
para não precisar recriar o schema a cada ajuste de escopo.

Eu (João Paulo) rodei o pipeline pela primeira vez e esbarrei em vários bloqueios de carga:
estouro de string no parser de CSV grande, cache de download falho e colunas reais do CSV do
SNGPC divergentes do que estava mapeado (`nu_ano_venda`, `sg_uf_venda` etc.), além de um
problema de idempotência no cache de período — corrigi tudo isso ainda na mesma semana e abri
o PR #1 com o Makefile e o `QUERIES.md` para padronizar os comandos de operação do projeto.
Eduardo documentou o uso de IA no projeto (`AI-USAGE.md`), por exigência da disciplina.

Os bloqueios de CSVs maiores do que o parser inicial suportava e de colunas divergentes da
documentação da fonte foram resolvidos ainda dentro da semana.

## Semana 8 — 29/09 a 05/10

Reunião na segunda (29/09) e na quarta (01/10). Eduardo otimizou o tempo de download e
inserção das tabelas do SNGPC (PR #2), resolvendo a lentidão e os erros que vínhamos
observando na primeira carga completa em Docker. Entre as reuniões, pelo WhatsApp da Squad,
alinhamos priorizar a estabilização da carga antes de avançar para as bases complementares da
E2, já que a ingestão do SNGPC ainda não rodava de ponta a ponta de forma confiável.

O bloqueio da semana — carga completa dos 12 meses ainda lenta e instável em Docker — foi
resolvido pelo próprio Eduardo nesse mesmo período.

## Semana 9 — 06/10 a 12/10

Na reunião de segunda (06/10) trouxemos a pauta da professora: confrontar o SNGPC com outras
bases públicas (issue #10). Fiquei (João Paulo) responsável por levantar e avaliar as fontes,
e entreguei o levantamento completo em `BASES_PUBLICAS.md`, avaliando seis bases candidatas —
IBGE população, IBGE faixa etária, DATASUS/CNES, DATASUS/SIA-SUS, FIRJAN/Atlas Brasil e INMET
— documentando para cada uma a granularidade, a licença e a pergunta nova que ela permite
responder.

Confirmamos por WhatsApp, fora da reunião de quarta, incorporar nesta entrega as três bases de
menor custo de integração: IBGE população por município, IBGE população por faixa etária e
INMET clima mensal por UF. CNES, SIA-SUS e FIRJAN/Atlas Brasil ficaram como candidatas para a
E3, por terem custo de ETL maior — o CNES só disponibiliza um dump de ~330 MB sem recorte, o
SIA-SUS exige conversão do formato DBC, e os portais do FIRJAN/Atlas Brasil são client-side e
não têm URL fixa de download. Implementei o preenchimento de `municipio.codigo_ibge` (que
resolveu de quebra uma dívida técnica do ADR), criei as tabelas
`ibge_populacao_municipio`, `ibge_populacao_faixa_etaria_municipio` e `clima_mensal_uf`, e
pluguei os respectivos scripts de carga no `docker-compose.yml`. Abri e mergeei o PR #11,
fechando a parte de bases públicas da issue #10.

Tive dois bloqueios nessa entrega: a API do INMET (`apitempo.inmet.gov.br`) respondia de
forma instável (404/204/500 inconsistentes), contornado usando o ZIP histórico estático do
portal; e a API do IBGE (tabela 9514, faixa etária) rejeitava pedir as 21 faixas etárias numa
única chamada, contornado fazendo uma chamada por faixa. Municípios com grafia muito
divergente entre Anvisa e IBGE ficaram sem `codigo_ibge` — registrei isso como limitação
conhecida, sem bloquear a entrega.

## Semana 10 — 13/10 (entrega)

Reunião de fechamento na segunda (13/10), antes da entrega marcada pela tag `e2`. Acertamos na
reunião e depois ajustamos detalhes pelo WhatsApp a divisão final de trabalho da E2: Eduardo
tornou a ingestão do SNGPC idempotente e reexecutável (PR #12, issue #3); Ruan construiu a
camada analítica/lakehouse, exportando `venda_medicamento` para Delta Lake sobre Parquet,
particionado por ano e mês, ordenado por UF/medicamento, com compressão ZSTD, compaction e
validação via DuckDB (PR #13, issues #5/#6); João Pedro detalhou a semântica at-least-once e
as chaves de idempotência de reprocessamento (PR #14, issue #7); Paola escreveu o ADR-E2 sobre
o mecanismo de ingestão, comparando CDC com recarga e Iceberg com Delta (PR #15, issue #9); e
eu fechei a issue #10 resumindo a tabela de status das bases complementares no `README.md` e
escrevendo este diário de bordo. Gabriel Freitas fez a integracao com o CDC que captura as mudancas
em tempo quase real e documenta um um arquivo texto e implementou a documentacao para um github pages.

Ficou em aberto, sem commit nesta janela, a issue #8 (tratamento de dado atrasado, atribuída ao Pedro Augusto), candidata a entrar na E3. Não houve bloqueio novo nesta semana: foi uma semana de consolidação e
fechamento, encerrada com a tag `e2` sobre a main consolidada com todas as entregas acima.

## 18/10 — dado atrasado (issue #8)

Eu (Pedro Augusto), fechei o tratamento de dado atrasado. A decisão está no ADR-003: a janela da dispensação é o mês da venda (`nu_ano_venda`, `nu_mes_venda`), não o mês do CSV. Se esse mês está no recorte e difere do arquivo, a linha entra nesse período e a contagem fica em `carga_arquivo.eventos_atrasados`. Se está fora do recorte, a linha é descartada e o motivo `periodo_fora_do_recorte` fica em `motivos_rejeicao`.

A demonstração usa os CSVs em `scripts/fixtures/dado_atrasado/`. `make simular-atraso` carrega o arquivo de fevereiro de 2020: a venda de janeiro entra em `202001`, a de fevereiro entra em `202002` e a de dezembro de 2019 é rejeitada. A saída está em `docs/evidencias/dado_atrasado.txt`.

`make reprocessar-janela` carrega antes o CSV de janeiro (quantidade 10 em `202001`) e depois o de fevereiro, que traz uma venda de janeiro (quantidade 1). Recarregar fevereiro executa `DELETE` e `COPY` só das linhas daquele `arquivo_origem`. A quantidade 10 permanece e a venda atrasada não duplica. A saída está em `docs/evidencias/reprocessamento_janela.txt`.

Não houve bloqueio novo.

## Semana 11 — 20/10 a 26/10

Semana de fechamento da documentação da E2, coordenada pelo WhatsApp da Squad. Eu (Eduardo)
publiquei a documentação do projeto no GitHub Pages com MkDocs (PR #17, configurado em 17/10),
escrevi `docs/ARQUITETURA.md` com o diagrama da plataforma e padronizei os nomes dos ADRs
(`ADR-001` a `ADR-003`), ajustando a navegação do site (PRs #22 e #23). Ruan escreveu as Release
Notes da E2 (`docs/entregas/E2.md`) e atualizou a lista de membros e a navegação. Os PRs da E2
que ainda estavam abertos — ingestão idempotente (#18 e #21), CDC com Debezium (#19) e dado
atrasado (#20) — já tinham sido mergeados em 18/10, então a `main` fechou a semana com a E2
inteira integrada.

Não houve bloqueio: o único ajuste foi refazer o deploy do Pages algumas vezes até a navegação
e os links relativos dos ADRs renomeados ficarem corretos.

## Semana 12 — 27/10 a 02/11

Semana de planejamento da E3, com pouca atividade no repositório: a Squad deu uma pausa no
código e não houve commits nesse período. Pelo WhatsApp, lemos o enunciado da E3 e dividimos o
checklist de aceite em issues, uma por pessoa:

| Issue | Tema | Responsável |
|---|---|---|
| #24 | Modelagem dimensional e dimensão de variação lenta (SCD) | João Paulo |
| #25 | Transformação declarativa em camadas (dbt / SQLMesh) | Pedro Augusto |
| #26 | Suíte de testes de qualidade de dados (integridade, volume e distribuição) | Gabriel |
| #27 | Orquestração com DAG, políticas de retry e demonstração de backfill | João Pedro |
| #28 | Otimização de performance com análise de plano de execução | Paola |
| #29 | SLA e métrica de freshness dos dados | Eduardo |
| #30 | ADR de decisão técnica e painel analítico da pergunta da E1 | Ruan |

A
professora adiou a entrega da E3 de 03/11 para 09/11, o que deu à Squad a semana 13 inteira
para implementar.

## Semana 13 — 03/11 a 09/11 (entrega)

Semana de implementação da E3, coordenada pelo WhatsApp, com os PRs entrando entre 07 e 09/11.

**Modelo dimensional (#24, PR #31, João Paulo).** Esquema estrela em PostgreSQL com grão de uma
linha por dispensação, `dim_municipio` como SCD Tipo 2 e as demais dimensões como views finas
com surrogate key determinística (`sk_hash()`, md5 da chave natural). A decisão está no ADR-004,
que avaliou e descartou o star schema no Delta Lake e o dbt snapshot por custo maior sem ganho
para a entrega. A revisão de código pegou três problemas antes do merge: colisão de surrogate key
quando um município muda duas vezes no mesmo dia, `sk_hash()` retornando um tipo que quebrava o
upgrade das views em banco já migrado, e vendas sumindo em silêncio no join temporal — agora a
carga da fato falha se a contagem não bater com `venda_medicamento`. Evidência em
`docs/evidencias/scd2.txt`.

**Testes de dados (#26, Gabriel).** Suíte em `tests/qualidade_dados.sql` (`make test-qualidade`)
cobrindo unicidade e nulos em PKs, integridade de todas as FKs, domínios (quantidade, idade,
sexo, campos de antimicrobiano), volume mínimo e igualdade de contagem entre origem e fato. O
teste de distribuição calcula o z-score mensal da série nacional e alerta com |z| > 3; um
autoteste injeta um salto sintético e confirma que ele é detectado (z = 3,32). Roda no CI com
doze linhas sintéticas. Evidência em `docs/evidencias/qualidade_dados.txt`.

**Orquestração (#27, PR #34, João Pedro).** DAG `farmadata_pipeline` no Airflow 2.10, agendada
`@monthly`: verificar fonte → extrair SNGPC → transformar modelo dimensional → validar qualidade,
com 3 retries e backoff exponencial. Com falha injetada, a fonte falhou duas vezes e passou na
terceira, com esperas de 39 s e 79 s (o backoff dobrando). O backfill de jan–jun/2020 rodou mês a
mês. O mês 202007, cujo CSV não existe, esgotou as 4 tentativas, disparou o alerta de falha e
deixou as tasks seguintes como `upstream_failed`, sem carga parcial. Evidências em
`docs/orchestration/`.

**Otimização de consulta (#28, Paola).** A query crítica do esquema estrela (fato + três
dimensões, recorte jan/2020, 6,1 milhões de linhas) levava 40,0 s. O `EXPLAIN (ANALYZE, BUFFERS)`
mostrou a surpresa da semana: as dimensões em view calculavam `sk_hash()` em tempo de execução e
retornavam `TEXT`, enquanto a fato guarda `CHAR(32)`, então o PostgreSQL fazia cast em todas as
linhas, errava a estimativa de cardinalidade e despejava 1,83 GB em disco temporário. Persistir as
surrogate keys com o mesmo tipo da fato, um índice parcial de cobertura e ajuste de `work_mem`
levaram a mesma query a 4,9 s (−87,7%), com leitura de blocos caindo 73,6% e spill zerado.
Planos antes/depois e estudo de ablação em `docs/performance/`.

**SLA e freshness (#29, PR #32, eu).** SLA declarado para a `fato_venda_medicamento`: ela é
reconstruída em até 24 h depois de cada carga, recarga ou backfill (como o recorte é fixo em
2020, não chega um mês novo por mês). A regra fica na função `checar_freshness()` (OK / WARN após
24 h / ERRO após 48 h ou tabela nunca construída), usada por `make checar-freshness` e por uma
DAG diária, `farmadata_freshness`, que grava alerta no WARN e falha sem retry no ERRO, bloqueando
o que vem a jusante. Na revisão percebi que a primeira versão não funcionava no banco real: ela
apontava para uma tabela que não existia e ninguém registrava quando a fato era reconstruída, então
o alarme daria sempre ERRO. Corrigi fazendo a própria carga da fato registrar o build na mesma
transação. Outra surpresa: o Docker monta cada `.sql` de `docker-entrypoint-initdb.d` como arquivo
único, e o container continua vendo a versão antiga de um arquivo regravado até ser reiniciado —
os testes passaram a ler o SQL direto do repositório. O atraso induzido disparando WARN e ERRO
está em `docs/evidencias/freshness.txt` e roda no CI a cada push.

**Transformação declarativa (#25, Pedro Augusto).** Até a #25 entrar, as transformações do modelo dimensional são funções PL/pgSQL versionadas em `sql/11` e `sql/12`; o ADR-004 descartou o dbt apenas para o versionamento SCD2 (snapshot), não para a camada de transformação como um todo.
Pós-implementação: o projeto dbt (dbt Core 1.12 com dbt-postgres) fica em `dbt/` e lê as tabelas de `public` como sources, organizado em três camadas: staging, com 13 views que limpam texto, renomeiam colunas legadas e fixam tipos; intermediate, com 3 views que fazem os joins com UF, CID-10, população do
IBGE e clima do INMET e aplicam a faixa etária e o cálculo per capita; e marts, com quatro dimensões
e dois fatos em tabela, gravados nos schemas `dbt_staging`, `dbt_intermediate` e `dbt_marts`. O
`fct_venda_medicamento` é incremental para não recopiar os cerca de 68 milhões de linhas a cada
execução. A surpresa foi a chave do incremental: a carga do SNGPC apaga e regrava um CSV inteiro
na recarga, e as linhas voltam com `id_venda` novo, então o incremental usa `delete+insert` por
`arquivo_origem` e o arquivo é substituído por inteiro, sem duplicar. Uma mudança de colunas no
modelo faz o `dbt run` falhar (`on_schema_change: fail`) em vez de ser ignorada em silêncio, e
obriga um `--full-refresh`. A `dim_municipio` do dbt guarda só o estado atual; o histórico SCD2
continua no PL/pgSQL, como decidido no ADR-004. Cada camada tem seu `schema.yml` descrevendo modelos
e colunas. Em banco temporário com as fixtures de dado atrasado, o `dbt build` passou os 22 modelos
sem erro, a venda atrasada de janeiro entrou no fato e a recarga forçada de fevereiro trocou as
linhas sem duplicar. No grafo de linhagem, só o staging lê as tabelas de origem.

**ADR e painel analítico (#30, Ruan).** Implementação do painel analítico em Streamlit (`src/dashboard/app.py`), acionável via `make dashboard`, respondendo de ponta a ponta à pergunta central de gestão da E1 através de três visões interativas: territorial e demanda per capita (cruzamento com IBGE População), sazonalidade climática (temperatura e chuva do INMET) e indicação diagnóstica (CID-10 para antimicrobianos). A decisão técnica de adotar o Streamlit conectado diretamente ao PostgreSQL Star Schema com cache em memória (`@st.cache_data`) foi registrada no ADR-005, acompanhada de benchmark comparativo reproduzível (`scripts/benchmark_painel.py`, `make benchmark-painel`). Também foi formalizado o vocabulário canônico em `GLOSSARY.md` e reestruturado o ADR-003 nos 6 passos com medição reproduzível em banco de simulação.

**Decisões da semana.** Star schema em PostgreSQL com `dim_municipio` em SCD2 e grão de uma linha por dispensação (ADR-004); Streamlit conectado ao PostgreSQL Star Schema para visualização analítica (ADR-005); checar o freshness numa DAG diária separada da mensal, porque logo depois da transformação a checagem sempre daria OK; manter o recorte em 2020 na E3 e deixar a carga de anos mais recentes como candidata para a E4.
