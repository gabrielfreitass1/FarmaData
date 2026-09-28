# FarmaData

> Plataforma de análise de venda de medicamentos controlados e antimicrobianos no Brasil (SNGPC/Anvisa, 2020).

## Pergunta de gestão

**Quais princípios ativos, municípios e períodos concentram o maior volume de dispensações de medicamentos controlados e antimicrobianos no Brasil em 2020, e como esses padrões se distribuem por região geográfica e faixa etária dos pacientes?**

---

## Pré-requisitos

| Ferramenta | Versão mínima |
|------------|--------------|
| Docker     | 24.x         |
| Docker Compose | v2 (plugin) |
| (Opcional) Node.js | 20.x — para rodar scripts fora do Docker |

---

## Como rodar do zero (comando único)

```bash
docker compose up
```

Isso irá:
1. **Subir o PostgreSQL 16** e aplicar todas as migrações SQL em ordem
2. **Baixar automaticamente** os 12 arquivos CSV mensais de medicamentos controlados e os 12 de antimicrobianos do portal de dados abertos da Anvisa (2020)
3. **Carregar o catálogo CID-10** do DATASUS
4. **Inserir todos os registros** nas tabelas normalizadas

> ⏱️ O tempo total depende da conexão de internet. Espere entre 20 e 60 minutos para os ~18 milhões de registros do ano de 2020.

---

## Configuração via variáveis de ambiente

Crie um arquivo `.env` na raiz do projeto (opcional — os valores padrão já funcionam localmente):

```env
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=farmadata
POSTGRES_PORT=5432
ANO_RECORTE=2020
```

---

## Estrutura do projeto

```
FarmaData/
├── sql/
│   ├── 01_geografia_uf.sql          # Etapa 2: tabela UF (27 registros fixos)
│   ├── 02_geografia_municipio.sql   # Etapa 2: estrutura da tabela de municípios
│   ├── 03_tempo_periodo.sql         # Etapa 2: 12 períodos do ano de recorte
│   ├── 04_medicamento.sql           # Etapa 3: princípio ativo + apresentação
│   ├── 05_cid10.sql                 # Etapa 3: estrutura da tabela CID-10
│   ├── 05_carga_catalogo_cid10.sql  # Etapa 3: carga gerada do catálogo DATASUS
│   ├── 06_prescritor_listas.sql     # Etapa 4: conselhos + listas fixas Anvisa
│   └── 07_venda_medicamento.sql     # Etapa 5: tabela fato de vendas + índices
├── scripts/
│   ├── carregar_cid10.js            # Etapa 3/6: gera o SQL de carga do CID-10
│   └── carregar_sngpc.js            # Etapa 6: download + carga dos CSVs SNGPC
├── docker-compose.yml               # Etapa 7: ambiente Docker completo
├── ADR.md                           # Etapa 1: decisão de modelagem (6 passos)
├── Entrega1.md                      # Critérios e checklist da E1
├── divisaoEntrega                   # Divisão de responsabilidades da equipe
└── README.md                        # Este arquivo
```

---

## Fontes de dados

| Fonte | URL |
|-------|-----|
| SNGPC / Anvisa | https://dados.gov.br/dados/conjuntos-dados/venda-de-medicamentos-controlados-e-antimicrobianos---medicamentos-industrializados |
| CID-10 DATASUS | https://datasus.saude.gov.br/transferencia-de-arquivos/ |
| Municípios IBGE | https://www.ibge.gov.br/estatisticas/sociais/populacao/9103-estimativas-de-populacao.html |

---

## Esquema do banco

```
unidade_federativa ──┐
                     ├─► municipio ──────────────────────┐
periodo ─────────────┼──────────────────────────────────►│
medicamento ─────────┼──────────────────────────────────►│──► venda_medicamento
conselho_profissional┼──────────────────────────────────►│
tipo_receituario ────┼──────────────────────────────────►│
unidade_medida ──────┼──────────────────────────────────►│
unidade_idade ───────┘──────────────────────────────────►│
cid10 ───────────────────────────────────────────────────┘
```

---

## Métricas do volume de dados (2020)

| Métrica | Valor |
|---------|-------|
| Registros na tabela `venda_medicamento` | ~18 milhões |
| Municípios distintos | ~5.500 |
| Princípios ativos distintos | ~1.200 |
| Tamanho do banco em disco | ~8 GB (com índices) |
| Tempo de query típica (agregação mensal por UF) | < 2s com índices |

> Os números acima são estimativas baseadas nos dados públicos da Anvisa para 2020. Execute `\dt+` no psql após a carga para os valores exatos.

---

## Conexão direta ao banco (sem Docker)

Se preferir rodar o PostgreSQL localmente:

```bash
# 1. Instale as dependências Node
npm install

# 2. Execute as migrações em ordem
psql -d farmadata -f sql/01_geografia_uf.sql
psql -d farmadata -f sql/02_geografia_municipio.sql
psql -d farmadata -f sql/03_tempo_periodo.sql
psql -d farmadata -f sql/04_medicamento.sql
psql -d farmadata -f sql/05_cid10.sql

# 3. Gere e carregue o catálogo CID-10
node scripts/carregar_cid10.js
psql -d farmadata -f sql/05_carga_catalogo_cid10.sql

# 4. Finalize o esquema
psql -d farmadata -f sql/06_prescritor_listas.sql
psql -d farmadata -f sql/07_venda_medicamento.sql

# 5. Baixe e carregue os CSVs SNGPC
DATABASE_URL=postgres://postgres:postgres@localhost:5432/farmadata node scripts/carregar_sngpc.js
```

---

## Licença

Dados públicos sob licença [Open Database License (ODbL)](https://opendatacommons.org/licenses/odbl/).  
Código do projeto sob [MIT License](LICENSE).