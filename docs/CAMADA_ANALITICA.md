# Camada analítica em formato aberto

Issues: #5 (formato aberto) e #6 (particionamento, serialização e compressão).

## Formato: Delta Lake sobre Parquet

| Critério | Delta Lake | Iceberg |
|---|---|---|
| Catálogo necessário | Não (`_delta_log/` no próprio diretório) | Sim (REST/Hive/Nessie/JDBC) para uso pleno |
| Escrita sem JVM | `deltalake` (delta-rs), pip install | `pyiceberg` (escrita mais limitada) |
| Leitura por DuckDB | `delta_scan` (extensão oficial) | `iceberg_scan` |
| Evolução de esquema | add/rename de coluna (column mapping) | mais rica (ids de coluna, evolução de partição) |
| Compactação | `optimize.compact()` nativo | `rewrite_data_files` (Spark) |

Escolhemos **Delta**: roda num container Python leve, sem catálogo nem Spark,
e o dado é Parquet comum + log JSON — qualquer motor lê. A evolução de
partição do Iceberg é a principal perda; nosso particionamento por mês é
estável, então não pesa. A decisão de formato é registrada também no ADR
da issue #7.

## Layout

```
data/lakehouse/delta/venda_medicamento/
├── _delta_log/
│   ├── 00000000000000000000.json      # commit inicial (schema, partições)
│   └── 0000000000000000000N.json      # um commit por mês exportado / compactação
├── ano=AAAA/mes=1/part-*.zstd.parquet
├── ano=AAAA/mes=2/...
└── ano=AAAA/mes=12/...
```

Modelo achatado (fato + atributos de dimensão usados nas consultas): evita
joins no motor de leitura e mantém o dado autoexplicativo fora do PostgreSQL.

## Particionamento

Consultas de [QUERIES.md](QUERIES.md): Q3/Q8 agregam por mês/trimestre;
Q2/Q4/Q8 por UF/região; Q1/Q8 por princípio ativo.

- **Partição `ano, mes`** — 12 partições/ano, ~5,7 M linhas cada. Poda direta
  em filtros temporais.
- **Não** particionamos por UF ou município: 27 × 12 = 324 diretórios (ou
  ~60 mil com município), muitos com poucos MB → *small files problem*
  (overhead de listagem, metadados e abertura de arquivo).
- **Ordenação interna `sigla_uf, id_medicamento`** — as estatísticas min/max
  de cada row group ficam estreitas, então filtros por UF/medicamento pulam
  row groups sem criar diretórios.

## Serialização e compressão

- **Parquet colunar**: as consultas leem 3–5 de 20 colunas.
- **ZSTD nível 3**: dado escrito uma vez por mês e lido muitas vezes. ZSTD
  comprime mais que Snappy (menos I/O por scan) com descompressão na mesma
  ordem de grandeza; GZIP comprime parecido mas descomprime mais devagar.
- **Row group de 500 mil linhas** e **arquivos-alvo de 128 MB**
  (`compactar_delta.py`): grandes o bastante para leitura sequencial, pequenos
  o bastante para paralelizar por arquivo.
- Dictionary encoding (padrão do writer) cobre colunas de baixa cardinalidade
  (`sigla_uf`, `regiao`, `tipo_receituario`, `eh_antimicrobiano`).

## Idempotência

`exportar_delta.py` grava cada mês com `mode="overwrite"` e
`predicate="ano = A AND mes = M"`: reexecutar substitui a partição em um único
commit atômico, sem duplicar. `validar_duckdb.py` checa `id_venda` duplicados
e compara contagens com o PostgreSQL.

## Como rodar

```bash
make lakehouse        # exporta, compacta e valida
make lakehouse-bench  # benchmark antes/depois
```

## Resultados do benchmark

| Métrica | Ingênuo (Snappy, ano/mes/UF, 50k linhas/arquivo) | Otimizado (ZSTD-3, ano/mes, ordenado, compactado) |
|---|---|---|
| Arquivos Parquet | 1524 | 12 |
| Tamanho em disco (MB) | 646.8 | 366.3 |
| Q3 evolução mensal (s, mediana de 5) | 0.644 | 0.192 |
| Q8 princípio x região x trimestre (s, mediana de 5) | 0.608 | 0.570 |
| Filtro UF+mês (DF, março) (s, mediana de 5) | 0.037 | 0.039 |


## SLA e freshness da tabela de consumo (issue #29)

**Tabela coberta:** a tabela de consumo do painel (`fato_municipio_mes`, nome a confirmar na #25).

**Definição.** Freshness é a defasagem entre a última carga em `carga_arquivo.carregado_em`
e a última construção da tabela de consumo, registrada em `controle_build.construido_em`.
Se não há carga posterior à última construção, a tabela está em dia.

**SLA.** A tabela de consumo é reconstruída em até **24 horas** após cada carga nova.

| Estado | Condição | Ação |
|---|---|---|
| OK | nenhuma carga posterior à última construção | nenhuma |
| WARN | carga pendente há mais de 24 h | avisar a squad e reconstruir |
| ERRO | carga pendente há mais de 48 h, ou tabela nunca construída | bloquear a atualização do painel e reconstruir |

**Limitação declarada.** A fonte (SNGPC) é histórica e publicada mensalmente. O SLA protege contra
falha do pipeline (carga feita e tabela não reconstruída), não contra dado desatualizado do mundo real.

**Verificação.** `make checar-freshness TABELA=...` (códigos de saída 0, 1 e 2, usáveis em CI ou no DAG da #27).
Prova do atraso induzido: `make test-freshness`, evidência em `docs/evidencias/freshness.txt`.

**Mitigação.** WARN: o log do pipeline registra o aviso e a squad reconstrói a tabela.
ERRO: a etapa seguinte (painel) não roda até a reconstrução, e a falha é tratada como incidente.

**Integração.** O teste de freshness roda no CI a cada push e pull request
(`.github/workflows/freshness.yml`). A tarefa de checagem no DAG de orquestração
fica para a issue #27.