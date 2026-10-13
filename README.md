# FarmaData

> Projeto da disciplina Sistemas de Bancos de Dados 2 — UnB.  
> Análise de venda de medicamentos controlados e antimicrobianos no Brasil (SNGPC/Anvisa, 2020).

**Pergunta de gestão:** Quais princípios ativos, municípios e períodos concentram o maior volume de dispensações em 2020, e como esses padrões se distribuem por região e faixa etária?

---

## Pré-requisitos

| Ferramenta | Versão |
|------------|--------|
| Docker + Docker Compose v2 | 24.x |
| Node.js (opcional, fora do Docker) | 20.x |

---

## Como rodar

```bash
docker compose up
```

Isso sobe o PostgreSQL, aplica todas as migrações em ordem, baixa os CSVs da Anvisa e popula o banco. Espere entre 20–60 minutos dependendo da conexão.

Para sobrescrever credenciais ou ano de recorte, crie um `.env`:

```env
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=farmadata
POSTGRES_PORT=5432
ANO_RECORTE=2020
```

### Camada analítica (Delta Lake + Parquet)

Com o banco já carregado:

```bash
make lakehouse        # exporta para data/lakehouse/delta, compacta e valida com DuckDB
make lakehouse-bench  # benchmark de layout antes/depois
```

Detalhes e justificativas em [`docs/CAMADA_ANALITICA.md`](docs/CAMADA_ANALITICA.md).

---

## Estrutura

```
FarmaData/
├── sql/
│   ├── 01_geografia_uf.sql         # UF: 27 registros fixos
│   ├── 02_geografia_municipio.sql  # Municípios (populado pela carga)
│   ├── 03_tempo_periodo.sql        # 12 meses de 2020
│   ├── 04_medicamento.sql          # Princípio ativo + apresentação
│   ├── 05_cid10.sql                # Estrutura da tabela CID-10
│   ├── 05_carga_catalogo_cid10.sql # Carga do catálogo DATASUS (gerado)
│   ├── 06_prescritor_listas.sql    # Conselhos + listas fixas Anvisa
│   ├── 07_venda_medicamento.sql    # Tabela fato + índices
│   ├── 08_ibge_populacao_municipio.sql # Estrutura: população por município/ano (IBGE)
│   ├── 09_clima_mensal_uf.sql      # Estrutura: clima mensal por UF (INMET)
│   └── 10_ibge_populacao_faixa_etaria_municipio.sql # Estrutura: população por faixa etária/município (IBGE)
├── scripts/
│   ├── carregar_cid10.js           # Gera 05_carga_catalogo_cid10.sql
│   ├── carregar_sngpc.js           # Download + carga dos CSVs SNGPC
│   ├── carregar_ibge_populacao.js  # codigo_ibge + população por município (IBGE/SIDRA)
│   ├── carregar_ibge_faixa_etaria.js # População por faixa etária/município (IBGE/SIDRA, Censo 2022)
│   └── carregar_inmet.js           # Clima mensal por UF (INMET, dados históricos por estação)
├── docker-compose.yml
├── ADR.md                          # Decisão de modelagem
└── README.md
```

---

## Esquema

```
unidade_federativa ──► municipio ──────────────────────┐
periodo ────────────────────────────────────────────────┤
medicamento ────────────────────────────────────────────┤──► venda_medicamento
conselho_profissional ──────────────────────────────────┤
tipo_receituario ───────────────────────────────────────┤
unidade_medida / unidade_idade ─────────────────────────┤
cid10 ──────────────────────────────────────────────────┘
```

---

## Fontes de dados

| Fonte | URL | Script |
|-------|-----|--------|
| SNGPC / Anvisa | https://dados.gov.br/dados/conjuntos-dados/venda-de-medicamentos-controlados-e-antimicrobianos---medicamentos-industrializados | `scripts/carregar_sngpc.js` |
| CID-10 DATASUS | https://datasus.saude.gov.br/transferencia-de-arquivos/ | `scripts/carregar_cid10.js` |
| População por município (IBGE/SIDRA) | https://servicodados.ibge.gov.br/api/v3/agregados/6579 | `scripts/carregar_ibge_populacao.js` |
| População por faixa etária/município (IBGE/SIDRA, Censo 2022) | https://servicodados.ibge.gov.br/api/v3/agregados/9514 | `scripts/carregar_ibge_faixa_etaria.js` |
| Clima mensal por UF (INMET) | https://portal.inmet.gov.br/dadoshistoricos | `scripts/carregar_inmet.js` |

### Bases complementares ao SNGPC

Levantamento completo em [`BASES_PUBLICAS.md`](BASES_PUBLICAS.md). Status:

| Base | Status |
|------|--------|
| IBGE — população por município | ✅ incorporada |
| IBGE — população por faixa etária/município | ✅ incorporada |
| INMET — clima mensal por UF | ✅ incorporada |
| DATASUS/CNES — estabelecimentos de saúde | ⚠️ avaliada, não incorporada (fica para a E3) |
| DATASUS/SIA-SUS — atendimentos ambulatoriais | ⚠️ avaliada, não incorporada (fica para a E3) |
| FIRJAN (IFDM) / Atlas Brasil (IDHM) | ⚠️ avaliada, não incorporada (fica para a E3) |

> Os municípios são extraídos automaticamente dos próprios CSVs do SNGPC durante a carga — não requerem fonte ou script separados.
>
> Outras bases públicas avaliadas para cruzamento com o SNGPC (e o motivo de ainda não terem entrado no banco) estão em [`BASES_PUBLICAS.md`](BASES_PUBLICAS.md).

---

## Volume (2020)

| Métrica | Valor |
|---------|-------|
| Registros em `venda_medicamento` | 68.264.756 (12 arquivos mensais) |
| Municípios distintos | 5088 |
| Princípios ativos distintos | 1231 |
| Tamanho em disco (com índices) | 10 GB |


---

## Ingestão em lote (SNGPC) — idempotência e reexecução
 
**Chave de idempotência:** o arquivo de origem (`EDA_Industrializados_AAAAMM.csv` → `venda_medicamento.arquivo_origem`).
Cada arquivo é carregado numa única transação: `DELETE` das linhas do arquivo → `COPY` → upsert em `carga_arquivo`.
Se algo falha, o `ROLLBACK` mantém o estado anterior; reexecutar nunca duplica linhas.
 
**Carga incremental:** `carga_arquivo` registra o que já foi carregado; uma nova execução processa só os meses ainda
ausentes (`make carga-incremental`). Um mês novo publicado pela Anvisa entra sozinho, sem tocar nos demais.
 
| Quero... | Comando |
|---|---|
| Carga completa/incremental | `make carga-incremental` |
| Só alguns meses | `make carga-sngpc MESES=202001,202002` |
| Recarregar mesmo já carregado | `make carga-sngpc MESES=202001 FORCE=1` |
| Provar a idempotência | `make test-idempotencia MES=202001` (evidência em `docs/evidencias/idempotencia.txt`) |
 
**O que esperar:** arquivo já carregado → `[SKIP]`; recarga → `[↻] N linhas anteriores removidas` e contagem final idêntica;
~260 s por mês (6 milhões de linhas). Duas cargas simultâneas são bloqueadas por advisory lock.
 
**Limitações assumidas:** a granularidade de reprocessamento é o arquivo mensal (não a linha); o `DELETE` de ~6 milhões
de linhas gera bloat — a evolução natural é particionar `venda_medicamento` por `id_periodo` e usar `TRUNCATE` da partição.

## Sem Docker

```bash
npm install
psql -d farmadata -f sql/01_geografia_uf.sql
psql -d farmadata -f sql/02_geografia_municipio.sql
psql -d farmadata -f sql/03_tempo_periodo.sql
psql -d farmadata -f sql/04_medicamento.sql
psql -d farmadata -f sql/05_cid10.sql
node scripts/carregar_cid10.js
psql -d farmadata -f sql/05_carga_catalogo_cid10.sql
psql -d farmadata -f sql/06_prescritor_listas.sql
psql -d farmadata -f sql/07_venda_medicamento.sql
psql -d farmadata -f sql/08_ibge_populacao_municipio.sql
psql -d farmadata -f sql/09_clima_mensal_uf.sql
psql -d farmadata -f sql/10_ibge_populacao_faixa_etaria_municipio.sql
DATABASE_URL=postgres://postgres:postgres@localhost:5432/farmadata node scripts/carregar_sngpc.js
DATABASE_URL=postgres://postgres:postgres@localhost:5432/farmadata node scripts/carregar_ibge_populacao.js
DATABASE_URL=postgres://postgres:postgres@localhost:5432/farmadata node scripts/carregar_ibge_faixa_etaria.js
DATABASE_URL=postgres://postgres:postgres@localhost:5432/farmadata node scripts/carregar_inmet.js
```