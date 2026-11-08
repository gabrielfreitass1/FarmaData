# Otimização de Performance com Análise de Plano de Execução (Issue #28)

**Entrega:** E3 — Camada Analítica Transformada e Testada  
**Banco de Dados:** PostgreSQL 16 (`farmadata_db`)  
**Camada Analisada:** Camada de Consumo — Esquema Estrela (`fato_venda_medicamento` + `dim_municipio` + `dim_tempo` + `dim_medicamento`)  
**Volume Avaliado:** `6.143.427` registros na `fato_venda_medicamento` (`1.263 MB` de heap / `161.683` páginas de 8 KB), `4.898` municípios em `dim_municipio` e `4.590` apresentações em `dim_medicamento`.

---

## 1. Identificação da Query Crítica da Camada de Consumo

A pergunta central de gestão do projeto declarada na E1 é:

> *"Quais princípios ativos, municípios e períodos concentram o maior volume de dispensações em um ano, e como esses padrões se distribuem por região e faixa etária?"*

Na camada de consumo modelada em Esquema Estrela ([`sql/11_dimensional_dim_municipio_scd.sql`](../../sql/11_dimensional_dim_municipio_scd.sql) e [`sql/12_dimensional_fato_venda.sql`](../../sql/12_dimensional_fato_venda.sql)), a consulta principal que alimenta o painel analítico cruza a tabela fato (`fato_venda_medicamento`) com as três dimensões principais (`dim_tempo`, `dim_municipio` e `dim_medicamento`), filtrando o subconjunto de antimicrobianos com idade informada num recorte regional/temporal e agregando o volume dispensado por município, UF, região, período, princípio ativo e faixa etária:

```sql
SELECT
    t.ano,
    t.mes,
    t.trimestre,
    dm.regiao,
    dm.sigla_uf,
    dm.nome_municipio,
    m.principio_ativo,
    CASE
        WHEN f.idade_paciente < 12 THEN '0-11 (criança)'
        WHEN f.idade_paciente < 18 THEN '12-17 (adolescente)'
        WHEN f.idade_paciente < 60 THEN '18-59 (adulto)'
        ELSE '60+ (idoso)'
    END AS faixa_etaria,
    SUM(f.quantidade_vendida) AS volume_total_dispensado,
    COUNT(*) AS total_dispensacoes
FROM fato_venda_medicamento f
JOIN dim_tempo t        ON t.sk_tempo = f.sk_tempo
JOIN dim_municipio dm   ON dm.sk_municipio = f.sk_municipio
JOIN dim_medicamento m  ON m.sk_medicamento = f.sk_medicamento
WHERE f.eh_antimicrobiano = TRUE
  AND f.idade_paciente IS NOT NULL
  AND t.ano = 2020
  AND dm.regiao = 'Sudeste'
GROUP BY
    t.ano, t.mes, t.trimestre,
    dm.regiao, dm.sigla_uf, dm.nome_municipio,
    m.principio_ativo,
    faixa_etaria
ORDER BY volume_total_dispensado DESC
LIMIT 50;
```

---

## 2. Diagnóstico do Plano Pré-Otimização (`explain_before.txt`)

O plano de execução completo antes da intervenção encontra-se em [`docs/performance/explain_before.txt`](explain_before.txt). A execução levou **39.968,84 ms (~40,0 s)** na 1ª execução e **45.191,54 ms (~45,2 s)** na execução com `VERBOSE, SETTINGS`.

A inspeção do `EXPLAIN (ANALYZE, BUFFERS)` revelou **quatro gargalos estruturais severos**:

### 2.1. `Seq Scan` Massivo na Tabela Fato (`1,26 GB` lidos da Heap)
```text
-> Seq Scan on public.fato_venda_medicamento f (cost=0.00..223118.66 rows=3440258 width=106) (actual time=0.134..2659.722 rows=4593047 loops=1)
     Filter: (f.eh_antimicrobiano AND (f.idade_paciente IS NOT NULL))
     Rows Removed by Filter: 1550380
     Buffers: shared hit=11040 read=150643
```
* A tabela `fato_venda_medicamento` armazena 6 chaves substitutas MD5 (`CHAR(32)`) além das chaves naturais e atributos degenerados, ocupando **1.263 MB (`161.683` blocos de 8 KB)**.
* Diferente da tabela OLTP `venda_medicamento`, a `fato_venda_medicamento` possuia apenas três índices B-Tree simples isolados (`sk_tempo`, `sk_municipio`, `sk_medicamento`) e **nenhum índice parcial para `eh_antimicrobiano = TRUE`** nem índice composto de cobertura (*covering index*).
* Como a tabela (`1.263 MB`) é muito maior que o `shared_buffers` padrão do container (`128 MB`), o PostgreSQL utiliza um *ring buffer* restrito para varreduras sequenciais, forçando **`150.643` leituras de blocos do disco/SO (`shared read`)** a cada execução e descartando `1.550.380` linhas em CPU.

### 2.2. Impedância de Tipos (`CHAR(32)` vs. `TEXT`) e Erro de Cardinalidade de 31x nos Joins
```text
-> Hash Join (cost=150.64..379902.76 rows=67808 width=74) (actual time=20.282..25938.250 rows=2122690 loops=1)
     Hash Cond: ((f.sk_tempo)::text = sk_hash('tempo'::text, periodo.id_periodo))
```
* Na `fato_venda_medicamento`, `sk_tempo` e `sk_medicamento` foram declaradas como `CHAR(32)` (`bpchar`), enquanto nas views `dim_tempo` e `dim_medicamento` a função `sk_hash()` retorna `TEXT`.
* Ao juntar `t.sk_tempo = f.sk_tempo` e `m.sk_medicamento = f.sk_medicamento`, o otimizador é forçado a converter a coluna da fato para texto (`(f.sk_tempo)::text`) e avaliar `sk_hash()` sobre as tabelas base sem estatísticas de expressão.
* Sem histograma/MCV para a expressão `sk_hash()`, o otimizador aplica uma seletividade padrão arbitrária e **subestima em 31 vezes a cardinalidade pós-join** (`rows=67808` estimadas contra **`rows=2122690` reais**).

### 2.3. `Merge Join` Custoso com `Sort` Externo em Disco (`245 MB` de Spill)
```text
-> Merge Join (cost=388744.64..818049.44 rows=1556194 width=97) (actual time=33984.822..38214.485 rows=2122690 loops=1)
     Merge Cond: ((sk_hash('medicamento'::text, medicamento.id_medicamento)) = ((f.sk_medicamento)::text))
     -> Sort (cost=388357.57..388527.09 rows=67808 width=74) (actual time=33916.824..34896.259 rows=2122690 loops=1)
          Sort Key: ((f.sk_medicamento)::text)
          Sort Method: external merge  Disk: 245320kB
          Buffers: shared hit=11112 read=150643, temp read=61326 written=61409
```
* Enganado pela subestimativa de `67.808` linhas do passo anterior e impedido de usar `idx_fato_venda_sk_medicamento` devido ao cast `::text`, o planejador escolhe um **`Merge Join`** precedido por um **`Sort`** e um **`Materialize`**.
* Ordenar `2.122.690` linhas por uma chave MD5 de 32 caracteres estoura o `work_mem` padrão (`4 MB`) e despeja **245.320 KB (~240 MB) em arquivos temporários de disco** (`temp read=61326 written=90409`).

### 2.4. `HashAggregate` Particionado em 129 Batches (`255 MB` de Spill) e Bloqueio de Paralelismo
```text
-> HashAggregate (cost=1074821.45..1154576.39 rows=1556194 width=132) (actual time=41904.666..43458.689 rows=216358 loops=1)
     Planned Partitions: 128  Batches: 129  Memory Usage: 8209kB  Disk Usage: 255040kB
     Buffers: shared hit=11186 read=150643, temp read=86753 written=147369
```
* A agregação final de `216.358` grupos com `work_mem = 4MB` particiona a tabela hash em **129 batches em disco**, consumindo mais **255.040 KB (~249 MB) de disco temporário**.
* Além disso, a função `sk_hash()` havia sido criada sem a cláusula `PARALLEL SAFE` (assumindo o padrão `PARALLEL UNSAFE` do PostgreSQL), **bloqueando completamente o uso de workers paralelos** em qualquer consulta sobre as views dimensionais.

---

## 3. Intervenções de Otimização Aplicadas (`sql/14_otimizacao_performance.sql`)

Todas as intervenções foram consolidadas de forma idempotente no script [`sql/14_otimizacao_performance.sql`](../../sql/14_otimizacao_performance.sql):

1. **Criação de Índice B-Tree Composto Parcial com Cobertura (`INCLUDE` / Covering Index) na Fato:**
   ```sql
   CREATE INDEX IF NOT EXISTS idx_fato_venda_antimicrobiano_covering
       ON fato_venda_medicamento (sk_municipio, id_periodo, id_medicamento)
       INCLUDE (idade_paciente, quantidade_vendida)
       WHERE eh_antimicrobiano = TRUE AND idade_paciente IS NOT NULL;
   ```
   * **Justificativa:** Filtra nativamente o subconjunto de antimicrobianos com idade válida (`WHERE eh_antimicrobiano = TRUE AND idade_paciente IS NOT NULL`), indexa as chaves compactas de junção (`sk_municipio`, `id_periodo`, `id_medicamento`) e inclui no *payload* da folha (`INCLUDE`) as colunas `idade_paciente` e `quantidade_vendida`. Com o *Visibility Map* atualizado via `VACUUM ANALYZE`, o PostgreSQL responde à consulta inteira via **`Index Only Scan` com `Heap Fetches: 0`** (sem tocar em nenhum bloco da tabela heap de 1,26 GB).
2. **Criação de Índice B-Tree de Cobertura em `dim_municipio` e Índice BRIN Temporal na Fato:**
   ```sql
   CREATE INDEX IF NOT EXISTS idx_dim_municipio_regiao_sk
       ON dim_municipio (regiao, sk_municipio)
       INCLUDE (sigla_uf, nome_municipio);

   CREATE INDEX IF NOT EXISTS idx_fato_venda_periodo_brin
       ON fato_venda_medicamento USING brin (data_venda, id_periodo)
       WITH (pages_per_range = 32);
   ```
   * **Justificativa:** O índice `idx_dim_municipio_regiao_sk` resolve o filtro regional e entrega `sk_municipio`, `sigla_uf` e `nome_municipio` em apenas 408 KB. Já o índice **BRIN** (`184 KB`) explora a ordenação física natural da carga por mês para podar intervalos de blocos em filtros temporais com custo de armazenamento desprezível (< 0,02% da heap).
3. **Índices Funcionais nas Dimensões Conformadas e `PARALLEL SAFE` em `sk_hash()`:**
   ```sql
   ALTER FUNCTION sk_hash(TEXT, ANYELEMENT) PARALLEL SAFE;
   CREATE UNIQUE INDEX IF NOT EXISTS idx_periodo_sk_tempo_bpchar ON periodo ((sk_hash('tempo', id_periodo)::char(32)));
   CREATE UNIQUE INDEX IF NOT EXISTS idx_periodo_sk_tempo_text   ON periodo (sk_hash('tempo', id_periodo));
   CREATE UNIQUE INDEX IF NOT EXISTS idx_medicamento_sk_med_bpchar ON medicamento ((sk_hash('medicamento', id_medicamento)::char(32)));
   CREATE UNIQUE INDEX IF NOT EXISTS idx_medicamento_sk_med_text   ON medicamento (sk_hash('medicamento', id_medicamento));
   ```
   * **Justificativa:** Desbloqueia a execução paralela no otimizador e força o `ANALYZE` a coletar estatísticas sobre `sk_hash()` nas tabelas `periodo` e `medicamento`.
4. **Reescrita dos Joins e Ajuste de Memória de Trabalho Analítica (`work_mem` e `jit`):**
   * Na consulta otimizada, os joins com as views `dim_tempo` e `dim_medicamento` passaram a usar as chaves inteiras indexadas já presentes tanto na fato quanto nas views (`t.id_periodo = f.id_periodo` e `m.id_medicamento = f.id_medicamento`), mantendo `dm.sk_municipio = f.sk_municipio` para preservar a rastreabilidade histórica da dimensão SCD Tipo 2 (`dim_municipio`). Isso elimina os casts `bpchar::text` e permite o uso direto do índice de cobertura compacto (`339 MB` em vez de `622 MB`).
   * Ajustou-se `ALTER DATABASE farmadata SET work_mem = '256MB'` e `jit = 'off'`, permitindo que o `HashAggregate` processe os `216.358` grupos integralmente em RAM (`Batches: 1`, `Memory Usage: 131089kB`), zerando o *spill to disk*.

---

## 4. Análise do Plano Pós-Otimização (`explain_after.txt`)

O plano pós-otimização completo está registrado em [`docs/performance/explain_after.txt`](explain_after.txt):

```text
 Limit  (cost=204041.54..204041.67 rows=50 width=132) (actual time=5731.509..5731.529 rows=50 loops=1)
   Buffers: shared hit=15199 read=11236
   ->  Sort  (cost=204041.54..206839.71 rows=1119269 width=132) (actual time=5731.507..5731.519 rows=50 loops=1)
         Sort Method: top-N heapsort  Memory: 37kB
         ->  HashAggregate  (cost=144474.85..166860.23 rows=1119269 width=132) (actual time=5356.294..5588.687 rows=216358 loops=1)
               Batches: 1  Memory Usage: 131089kB
               Buffers: shared hit=15196 read=11236
               ->  Hash Join  (cost=167.13..122089.47 rows=1119269 width=97) (actual time=4.640..2849.495 rows=2122690 loops=1)
                     Hash Cond: (f.id_medicamento = medicamento.id_medicamento)
                     ->  Hash Join  (cost=1.86..110588.88 rows=1119269 width=49) (actual time=0.287..1954.212 rows=2122690 loops=1)
                           Hash Cond: (f.id_periodo = periodo.id_periodo)
                           ->  Nested Loop  (cost=0.56..106611.85 rows=1119269 width=41) (actual time=0.124..1199.110 rows=2122690 loops=1)
                                 ->  Seq Scan on public.dim_municipio dm  (cost=0.00..129.22 rows=1609 width=55) (actual time=0.049..3.653 rows=1609 loops=1)
                                       Filter: ((dm.regiao)::text = 'Sudeste'::text)
                                 ->  Index Only Scan using idx_fato_venda_antimicrobiano_covering on public.fato_venda_medicamento f  (cost=0.56..55.61 rows=1057 width=52) (actual time=0.021..0.487 rows=1319 loops=1609)
                                       Index Cond: (f.sk_municipio = dm.sk_municipio)
                                       Heap Fetches: 0
                                       Buffers: shared hit=15196 read=11105
Execution Time: 5810.011 ms
```

* **Varredura da Fato em `1,19 s` com `Heap Fetches: 0`:** O `Nested Loop` guiado pelos `1.609` municípios do Sudeste acessa diretamente o índice `idx_fato_venda_antimicrobiano_covering` via `Index Only Scan`, extraindo as `2.122.690` linhas relevantes em **1.199,11 ms** sem visitar nenhuma página da tabela heap.
* **Joins em Memória em `2,85 s`:** Os dois `Hash Joins` com `periodo` (9 KB) e `medicamento` (379 KB) concluem todas as `2.122.690` junções aos `2.849,49 ms`, eliminando por completo o `Sort` externo e o `Merge Join`.
* **Zero Spill to Disk (`temp read=0, written=0`):** O `HashAggregate` consolida as `2.122.690` linhas em `216.358` grupos num único lote em memória (`Batches: 1`).

---

## 5. Relatório Comparativo de Métricas (Antes vs. Depois)

| Métrica / Indicador do Plano | Pré-Otimização (`explain_before.txt`) | Pós-Otimização (`explain_after.txt`) | Variação / Ganho Obtido |
| :--- | :--- | :--- | :--- |
| **Tempo Total (`Execution Time` — Warm/Verbose)** | `45.191,538 ms` (~45,2 s) | **`5.810,011 ms`** (~5,8 s) | **-87,1% (`7,78x` mais rápido)** |
| **Tempo Total (`Execution Time` — 1ª Execução)** | `39.968,842 ms` (~40,0 s) | **`8.462,517 ms`** (~8,5 s) | **-78,8% (`4,72x` mais rápido)** |
| **Custo Estimado pelo Otimizador (`Total Cost`)** | `1.206.272,16` | **`204.041,67`** | **-83,1% no custo estimado** |
| **Operador de Leitura na `fato_venda_medicamento`** | `Seq Scan` (varre 6,14M linhas + filtra 1,55M) | **`Index Only Scan`** (`Heap Fetches: 0`) | **100% dos acessos à heap eliminados** |
| **Operador de Junção com `dim_medicamento`** | `Sort (external merge 245MB)` + `Merge Join` | **`Hash Join` em memória (`379 KB`)** | **Eliminação do Sort externo** |
| **Buffers Compartilhados Totais (`shared hit + read`)** | `161.832` blocos (`1.264,3 MB`) | **`26.435` blocos (`206,5 MB`)** | **-83,7% (`-135.397` blocos / `-1,03 GB`)** |
| **Leituras Físicas/SO (`shared read`)** | `150.643` blocos (`1.176,9 MB`) | **`11.236` blocos (`87,8 MB`)** | **-92,5% de leitura de disco/SO** |
| **Hits em Cache de Buffer (`shared hit`)** | `11.189` blocos (`87,4 MB`) | **`15.199` blocos (`118,7 MB`)** | **Maior retenção no buffer pool** |
| **Buffers Temporários Lidos (`temp read`)** | `86.753` blocos (`677,8 MB`) | **`0` blocos (`0 MB`)** | **-100% (Spill to Disk eliminado)** |
| **Buffers Temporários Escritos (`temp written`)** | `147.369` blocos (`1.151,3 MB`) | **`0` blocos (`0 MB`)** | **-100% (Spill to Disk eliminado)** |
| **Partições do `HashAggregate` (`Batches`)** | `129` batches (`Disk Usage: 255.040 KB`) | **`1` batch (`Disk Usage: 0 KB`)** | **100% processado em RAM** |
| **Volume Total de I/O de Blocos (`shared + temp`)** | `395.954` blocos (**`3.093,4 MB` / `3,02 GB`**) | **`26.435` blocos (**`206,5 MB`**)** | **-93,3% de I/O total (`15x` menos blocos)** |

---

## 6. Como Reproduzir

Com o banco carregado e o modelo dimensional populado (`make modelo-dimensional`):

```bash
# Aplicar apenas as otimizações estruturais e atualizar o Visibility Map
make otimizar-performance

# Executar o benchmark completo (gera explain_before.txt e explain_after.txt)
make benchmark-performance
```
