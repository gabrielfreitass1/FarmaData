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
│   └── 07_venda_medicamento.sql    # Tabela fato + índices
├── scripts/
│   ├── carregar_cid10.js           # Gera 05_carga_catalogo_cid10.sql
│   └── carregar_sngpc.js           # Download + carga dos CSVs SNGPC
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

> Os municípios são extraídos automaticamente dos próprios CSVs do SNGPC durante a carga — não requerem fonte ou script separados.

---

## Volume estimado (2020)

| Métrica | Valor |
|---------|-------|
| Registros em `venda_medicamento` | ~18 milhões |
| Municípios distintos | ~5.500 |
| Princípios ativos distintos | ~1.200 |
| Tamanho em disco (com índices) | ~8 GB |

> Execute `\dt+` no psql após a carga para os valores reais.

---

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
DATABASE_URL=postgres://postgres:postgres@localhost:5432/farmadata node scripts/carregar_sngpc.js
```