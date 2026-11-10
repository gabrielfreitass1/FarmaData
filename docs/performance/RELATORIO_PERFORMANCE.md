# Otimização de Performance com Análise de Plano de Execução (Issue #28)

**Entrega:** E3 — Camada Analítica Transformada e Testada  
**Banco de Dados:** PostgreSQL 16 (`farmadata_db`)  
**Camada Analisada:** Camada de Consumo — Esquema Estrela (`fato_venda_medicamento` + `dim_municipio` + `dim_tempo` + `dim_medicamento`)  
**Recorte de Dados do Benchmark:** Lote SNGPC `202001` (**Janeiro/2020** — `6.143.427` registros na `fato_venda_medicamento`, ocupando `1.263 MB` de heap / `161.683` páginas de 8 KB; `4.898` linhas em `dim_municipio`; `4.590` apresentações em `dim_medicamento`; `12` meses cadastrados em `dim_tempo`).  
*(A projeção de capacidade e comportamento para o ano completo de 12 meses — `68.264.756` registros — encontra-se detalhada na [Seção 6](#6-projecao-de-escalabilidade-para-o-ano-completo-12-meses--6826-milhoes-de-linhas)).*

---

## 1. Identificação da Query Crítica e Escopo do Dataset

### 1.1. Consulta Analítica Avaliada (100% Idêntica Antes e Depois)

A pergunta central de gestão do projeto declarada na E1 é:

> *"Quais princípios ativos, municípios e períodos concentram o maior volume de dispensações em um ano, e como esses padrões se distribuem por região e faixa etária?"*

Na camada de consumo modelada em Esquema Estrela ([`sql/11_dimensional_dim_municipio_scd.sql`](../../sql/11_dimensional_dim_municipio_scd.sql) e [`sql/12_dimensional_fato_venda.sql`](../../sql/12_dimensional_fato_venda.sql)), a consulta crítica que alimenta o painel analítico cruza a tabela fato (`fato_venda_medicamento`) com as três dimensões do modelo estrela (`dim_tempo`, `dim_municipio` e `dim_medicamento`) **utilizando exclusivamente as chaves substitutas (`sk_tempo`, `sk_municipio`, `sk_medicamento`)**.

Para garantir rigor metodológico na comparação, **exatamente a mesma consulta SQL** (sem alterar uma única linha) foi executada antes ([`explain_before.txt`](explain_before.txt)) e depois ([`explain_after.txt`](explain_after.txt)) das intervenções estruturais:

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

### 1.2. Escopo dos Dados no Benchmark: Janeiro/2020 (`202001`) vs. Ano Completo (`202001–202012`)

* O ambiente local de benchmark contém carregado o lote oficial SNGPC **`202001` (Janeiro/2020)**, que possui exatamente **`6.143.427` linhas** na `fato_venda_medicamento` (`4.593.047` das quais são dispensações de antimicrobianos com `idade_paciente IS NOT NULL`, e `2.122.690` pertencem à região Sudeste).
* Embora a consulta filtre `t.ano = 2020` e a tabela `periodo` possua os 12 meses de 2020 pré-cadastrados (`id_periodo` de `202001` a `202012`), todas as `6.143.427` linhas presentes na fato pertencem à competência **Janeiro/2020 (`id_periodo = 202001`)**.
* A base anual completa de 2020 no SNGPC soma **`68.264.756` linhas** (`11,11x` o volume de janeiro). Na [Seção 6](#6-projecao-de-escalabilidade-para-o-ano-completo-12-meses--6826-milhoes-de-linhas), demonstramos matematicamente como cada estrutura de armazenamento e cada operador do plano escalam para os 12 meses completos.

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
* A tabela `fato_venda_medicamento` armazena 6 chaves substitutas MD5 (`CHAR(32)`) além das chaves naturais e atributos degenerados, ocupando **1.263 MB (`161.683` blocos de 8 KB)** apenas para Janeiro/2020.
* A `fato_venda_medicamento` possuía apenas três índices B-Tree simples isolados (`sk_tempo`, `sk_municipio`, `sk_medicamento`) e **nenhum índice parcial para `eh_antimicrobiano = TRUE`** nem índice composto de cobertura (*covering index*).
* Como a tabela (`1.263 MB`) é muito maior que o `shared_buffers` padrão do container (`128 MB`), o PostgreSQL utiliza um *ring buffer* restrito para varreduras sequenciais, forçando **`150.643` leituras de blocos do disco/SO (`shared read`)** e descartando `1.550.380` linhas em CPU.

### 2.2. Impedância de Tipos (`CHAR(32)` vs. `TEXT`) e Erro de Cardinalidade de 31x nos Joins
```text
-> Hash Join (cost=150.64..379902.76 rows=67808 width=74) (actual time=20.282..25938.250 rows=2122690 loops=1)
     Hash Cond: ((f.sk_tempo)::text = sk_hash('tempo'::text, periodo.id_periodo))
```
* Na `fato_venda_medicamento`, `sk_tempo` e `sk_medicamento` foram declaradas como `CHAR(32)` (`bpchar`), enquanto nas views `dim_tempo` e `dim_medicamento` a função `sk_hash()` calculava o MD5 em tempo de execução retornando `TEXT` (dívida técnica documentada no [`ADR-004.md`](../adr/ADR-004.md), seção 5: *"As dimensões conformadas (views) não têm `sk_*` persistida"*).
* Ao juntar `t.sk_tempo = f.sk_tempo` e `m.sk_medicamento = f.sk_medicamento`, o otimizador é forçado a aplicar o cast `(f.sk_tempo)::text` e `(f.sk_medicamento)::text` em todas as `4.593.047` linhas da fato e avaliar `sk_hash()` sem estatísticas de coluna.
* Sem estatísticas para a expressão, o otimizador **subestima em 31 vezes a cardinalidade pós-join** (`rows=67808` estimadas contra **`rows=2122690` reais**), gastando **~22 segundos** apenas na conversão e comparação de hashes em CPU.

### 2.3. `Merge Join` Custoso com `Sort` Externo em Disco (`245 MB` de Spill)
```text
-> Merge Join (cost=388744.64..818049.44 rows=1556194 width=97) (actual time=33984.822..38214.485 rows=2122690 loops=1)
     Merge Cond: ((sk_hash('medicamento'::text, medicamento.id_medicamento)) = ((f.sk_medicamento)::text))
     -> Sort (cost=388357.57..388527.09 rows=67808 width=74) (actual time=33916.824..34896.259 rows=2122690 loops=1)
          Sort Key: ((f.sk_medicamento)::text)
          Sort Method: external merge  Disk: 245320kB
          Buffers: shared hit=11112 read=150643, temp read=61326 written=61409
```
* Enganado pela subestimativa de `67.808` linhas do passo anterior e impedido de usar estatísticas devido ao cast `::text`, o planejador escolhe um **`Merge Join`** precedido por um **`Sort`** e um **`Materialize`**.
* Ordenar `2.122.690` linhas por uma chave MD5 de 32 caracteres estoura o `work_mem` padrão (`4 MB`) e despeja **245.320 KB (~240 MB) em arquivos temporários de disco** (`temp read=61326 written=90409`).

### 2.4. `HashAggregate` Particionado em 129 Batches (`255 MB` de Spill) e Bloqueio de Paralelismo
```text
-> HashAggregate (cost=1074821.45..1154576.39 rows=1556194 width=132) (actual time=41904.666..43458.689 rows=216358 loops=1)
     Planned Partitions: 128  Batches: 129  Memory Usage: 8209kB  Disk Usage: 255040kB
     Buffers: shared hit=11186 read=150643, temp read=86753 written=147369
```
* A agregação final de `216.358` grupos com `work_mem = 4MB` particiona a tabela hash em **129 batches em disco**, consumindo mais **255.040 KB (~249 MB) de disco temporário**.
* Além disso, a função `sk_hash()` havia sido criada sem a cláusula `PARALLEL SAFE` (assumindo o padrão `PARALLEL UNSAFE` do PostgreSQL), **bloqueando completamente o uso de workers paralelos**.

---

## 3. Intervenções Aplicadas (`sql/11` + `sql/14` + Sessão Analítica)

Para manter a separação limpa entre **modelo dimensional** e **índices de performance** (e garantir idempotência em qualquer ordem de reaplicação de scripts):
* As colunas geradas armazenadas (`CHAR(32) STORED`) e as views `dim_tempo` e `dim_medicamento` têm **definição única** em [`sql/11_dimensional_dim_municipio_scd.sql`](../../sql/11_dimensional_dim_municipio_scd.sql) (formalizada na Emenda ao [`ADR-004.md`](../adr/ADR-004.md) e no dicionário de [`MODELO_DIMENSIONAL.md`](../MODELO_DIMENSIONAL.md)).
* O script [`sql/14_otimizacao_performance.sql`](../../sql/14_otimizacao_performance.sql) contém **exclusivamente índices e estatísticas (`ANALYZE`)**.
* O ajuste de `work_mem` e `jit` é aplicado **apenas na sessão analítica** (ou no `ROLE` do painel via `ALTER ROLE painel SET work_mem = '256MB'`), nunca via `ALTER DATABASE`, para não impactar conexões de carga/ETL.

Cada intervenção tem participação direta e verificável no plano de execução pós-otimização:

1. **Fator A — Materialização e Tipagem Estrita `CHAR(32)` das Surrogate Keys nas Dimensões Conformadas (`sql/11`) + Índices `UNIQUE` (`sql/14`):**
   ```sql
   -- Em sql/11_dimensional_dim_municipio_scd.sql:
   CREATE OR REPLACE FUNCTION sk_hash(p_dimensao TEXT, p_chave_natural ANYELEMENT)
   RETURNS TEXT AS $$
       SELECT md5(p_dimensao || '|' || p_chave_natural);
   $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

   ALTER TABLE periodo
       ADD COLUMN IF NOT EXISTS sk_tempo CHAR(32)
       GENERATED ALWAYS AS (sk_hash('tempo', id_periodo)::char(32)) STORED;

   ALTER TABLE medicamento
       ADD COLUMN IF NOT EXISTS sk_medicamento CHAR(32)
       GENERATED ALWAYS AS (sk_hash('medicamento', id_medicamento)::char(32)) STORED;

   DROP VIEW IF EXISTS dim_tempo;
   CREATE VIEW dim_tempo AS
   SELECT sk_tempo, id_periodo, ano, mes, nome_mes, trimestre, semestre, data_inicio, data_fim
   FROM periodo;

   DROP VIEW IF EXISTS dim_medicamento;
   CREATE VIEW dim_medicamento AS
   SELECT sk_medicamento, id_medicamento, principio_ativo, descricao_apresentacao
   FROM medicamento;

   -- Em sql/14_otimizacao_performance.sql:
   CREATE UNIQUE INDEX IF NOT EXISTS idx_periodo_sk_tempo ON periodo (sk_tempo);
   CREATE UNIQUE INDEX IF NOT EXISTS idx_medicamento_sk_medicamento ON medicamento (sk_medicamento);
   ```
   * **Efeito:** Resolve a dívida técnica do [`ADR-004.md`](../adr/ADR-004.md) persistindo `sk_tempo` e `sk_medicamento` com o mesmo tipo `CHAR(32)` (`bpchar`) da tabela fato e expondo-as nas views `dim_tempo` e `dim_medicamento`. Isso **elimina o cast `(f.sk_*)::text`** sem tocar na query SQL, corrige o erro de estimativa de cardinalidade de 31x, substitui o `Merge Join + Sort (245 MB)` por `Hash Join` em memória e ativa a propriedade **`Inner Unique: true`** no otimizador graças aos índices `UNIQUE`.
   * **Compatibilidade com a Carga e Idempotência:** Como `sql/03_tempo_periodo.sql` e `scripts/carregar_sngpc.js` inserem em `periodo` e `medicamento` declarando explicitamente a lista de colunas, as colunas `GENERATED ALWAYS ... STORED` são populadas automaticamente sem quebrar a ingestão nem a exportação Delta/CDC (comprovado automaticamente em `make test-scd2`, que aplica `sql/11`, `sql/12` e `sql/14` duas vezes seguidas e testa `INSERT` em `medicamento` e `periodo`).

2. **Fator B — Índice B-Tree Composto Parcial com Cobertura (`INCLUDE` / Covering Index) na Fato (`sql/14`):**
   ```sql
   CREATE INDEX IF NOT EXISTS idx_fato_venda_antimicrobiano_covering
       ON fato_venda_medicamento (sk_municipio, sk_tempo, sk_medicamento)
       INCLUDE (idade_paciente, quantidade_vendida)
       WHERE eh_antimicrobiano = TRUE AND idade_paciente IS NOT NULL;
   ```
   * **Efeito:** Indexa diretamente as três surrogate keys usadas nos joins da query original (`sk_municipio`, `sk_tempo`, `sk_medicamento`), filtra nativamente o predicado `WHERE eh_antimicrobiano = TRUE AND idade_paciente IS NOT NULL` e inclui no *payload* das páginas-folha (`INCLUDE`) as colunas `idade_paciente` e `quantidade_vendida`. Após `VACUUM ANALYZE`, permite responder à consulta via **`Index Only Scan` com `Heap Fetches: 0`**, reduzindo os blocos compartilhados lidos de **`161.832` para `42.751` (-73,6%)**.
   * **Ressalva Operacional:** Como `CREATE INDEX` (sem `CONCURRENTLY`) adquire lock de escrita na `fato_venda_medicamento` durante a construção, `make otimizar-performance` deve ser executado após o término da carga, nunca concorrentemente a ela.

3. **Fator C — Ajuste de Memória de Trabalho na Sessão Analítica / Role do Painel (`work_mem = '256MB'` e `jit = 'off'`):**
   ```sql
   -- Na sessão do benchmark/painel (ou via ALTER ROLE painel SET work_mem = '256MB'):
   SET work_mem = '256MB';
   SET jit = 'off';
   ```
   * **Efeito:** Permite que o `HashAggregate` final aloque `131.089 KB (~128 MB)` em RAM e consolide os `216.358` grupos em **1 único lote (`Batches: 1`)**, reduzindo o *spill to disk* de `234.122` blocos temporários (`1,83 GB`) para **zero (`temp read=0, written=0`)**, sem alterar o `work_mem` global do banco (`4MB`) usado pelos processos de ingestão.

---

## 4. Análise do Plano Pós-Otimização e Isolamento de Fatores (Ablação)

### 4.1. Plano de Execução Pós-Otimização (`explain_after.txt`)

O plano pós-otimização completo (executando **exatamente a mesma query SQL**) está registrado em [`docs/performance/explain_after.txt`](explain_after.txt):

```text
 Limit  (cost=248982.01..248982.14 rows=50 width=132) (actual time=4860.728..4860.740 rows=50 loops=1)
   Buffers: shared hit=4819 read=37932
   ->  Sort  (cost=248982.01..251805.88 rows=1129548 width=132) (actual time=4860.726..4860.734 rows=50 loops=1)
         Sort Key: (sum(f.quantidade_vendida)) DESC
         Sort Method: top-N heapsort  Memory: 37kB
         Buffers: shared hit=4819 read=37932
         ->  HashAggregate  (cost=188868.28..211459.24 rows=1129548 width=132) (actual time=4656.105..4780.018 rows=216358 loops=1)
               Group Key: periodo.mes, periodo.trimestre, dm.sigla_uf, dm.nome_municipio, medicamento.principio_ativo, CASE ...
               Batches: 1  Memory Usage: 131089kB
               Buffers: shared hit=4819 read=37932
               ->  Hash Join  (cost=233.13..166277.32 rows=1129548 width=97) (actual time=15.425..2798.269 rows=2122690 loops=1)
                     Inner Unique: true
                     Hash Cond: (f.sk_medicamento = medicamento.sk_medicamento)
                     Buffers: shared hit=4819 read=37932
                     ->  Hash Join  (cost=1.86..154606.64 rows=1129548 width=74) (actual time=9.591..1885.395 rows=2122690 loops=1)
                           Inner Unique: true
                           Hash Cond: (f.sk_tempo = periodo.sk_tempo)
                           Buffers: shared hit=4817 read=37806
                           ->  Nested Loop  (cost=0.56..150593.09 rows=1129548 width=95) (actual time=9.492..1086.583 rows=2122690 loops=1)
                                 Buffers: shared hit=4817 read=37805
                                 ->  Seq Scan on public.dim_municipio dm  (cost=0.00..129.22 rows=1609 width=55) (actual time=9.388..16.462 rows=1609 loops=1)
                                       Filter: ((dm.regiao)::text = 'Sudeste'::text)
                                       Rows Removed by Filter: 3289
                                       Buffers: shared read=68
                                 ->  Index Only Scan using idx_fato_venda_antimicrobiano_covering on public.fato_venda_medicamento f  (cost=0.56..82.89 rows=1062 width=106) (actual time=0.019..0.449 rows=1319 loops=1609)
                                       Index Cond: (f.sk_municipio = dm.sk_municipio)
                                       Heap Fetches: 0
                                       Buffers: shared hit=4817 read=37737
                           ->  Hash  (cost=1.15..1.15 rows=12 width=45) (actual time=0.067..0.067 rows=12 loops=1)
                                 Buckets: 1024  Batches: 1  Memory Usage: 9kB
                                 Buffers: shared read=1
                                 ->  Seq Scan on public.periodo  (cost=0.00..1.15 rows=12 width=45) (actual time=0.038..0.043 rows=12 loops=1)
                                       Filter: (periodo.ano = 2020)
                                       Buffers: shared read=1
                     ->  Hash  (cost=173.90..173.90 rows=4590 width=59) (actual time=5.747..5.748 rows=4590 loops=1)
                           Buckets: 8192  Batches: 1  Memory Usage: 473kB
                           Buffers: shared hit=2 read=126
                           ->  Seq Scan on public.medicamento  (cost=0.00..173.90 rows=4590 width=59) (actual time=0.014..2.055 rows=4590 loops=1)
                                 Buffers: shared hit=2 read=126
 Settings: work_mem = '256MB', jit = 'off'
 Planning Time: 3.572 ms
 Execution Time: 4916.431 ms
```

### 4.2. Estudo de Ablação — Isolamento do Ganho de Cada Intervenção

Para comprovar exatamente quanto cada fator contribui para o resultado final sem misturar efeitos, as três intervenções foram aplicadas incrementalmente sobre a **mesma query SQL**:

| Etapa Incremental (Mesma Query SQL) | Operadores Principais Escolhidos pelo Planejador | Blocos `shared` (`hit + read`) | Blocos `temp` (`read + written`) | Tempo dos Scans + Joins | Tempo Total (`Execution Time`) | O que Esta Etapa Isoladamente Resolve |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **0. Baseline Pré-Otimização** (`explain_before.txt`) | `Seq Scan` na fato + `Hash Join (::text)` + `Sort (245MB disk)` + `Merge Join` + `HashAggregate (129 batches)` | `161.832` (`1.264,3 MB`) | `234.122` (`1.829,1 MB`) | `32.571,34 ms` | **`39.968,84 ms`** *(45.191,54 ms verbose)* | Estado inicial: cast `CHAR(32)::text`, erro de 31x na cardinalidade, 2 spills em disco e leitura total da heap. |
| **1. + Fator A** *(Persistência `CHAR(32)` de `sk_tempo` e `sk_medicamento` + `UNIQUE` + `PARALLEL SAFE`, sem índice na fato, `work_mem=4MB`)* | `Parallel Seq Scan` (2 workers) + 3 `Hash Joins` diretos (`bpchar = bpchar`) + `Parallel Sort` + `GroupAggregate` | `162.397` (`1.268,7 MB`) | `102.791` (`803,1 MB`) | `2.673,83 ms` *(por worker)* | **`9.025,99 ms`** **(-77,4%)** | **Elimina o cast `::text` e o `Merge Join + Sort (245 MB)`**, reduzindo o tempo em **-30,9 s** e o temp I/O em **-56,1%**, mas **continua lendo 100% da heap da fato (`161.683` blocos)**. |
| **2. + Fator B** *(+ Índice de Cobertura Parcial `idx_fato_venda_antimicrobiano_covering` + `VACUUM ANALYZE`, mantendo `work_mem=4MB`)* | `Nested Loop` + **`Index Only Scan (Heap Fetches: 0)`** + 2 `Hash Joins (Inner Unique)` + `HashAggregate (65 batches disk)` | **`42.751`** (`334,0 MB`) **(-73,6%)** | `84.188` (`657,7 MB`) | **`4.690,33 ms`** *(1 processo)* | **`9.554,63 ms`** *(4,69s joins + 4,86s spill)* | **Corta 73,6% dos blocos compartilhados lidos (`-119.081` blocos / `-930,3 MB`)** e zera acessos à heap (`Heap Fetches: 0`), mas com `work_mem=4MB` a agregação final ainda gasta `4,86 s` gravando `65 batches` em disco. |
| **3. + Fator C** *(+ `work_mem = '256MB'` e `jit = 'off'` — `explain_after.txt`)* | `Nested Loop` + **`Index Only Scan (Heap Fetches: 0)`** + 2 `Hash Joins (Inner Unique)` + **`HashAggregate (Batches: 1, RAM)`** | **`42.751`** (`334,0 MB`) **(-73,6%)** | **`0`** (`0 MB`) **(-100%)** | **`2.798,27 ms`** | **`4.916,43 ms`** *(4.920,51 ms 1ª exec)* **(-87,7% / -89,1%)** | **Elimina 100% do spill do `HashAggregate` (`Batches: 1`)**, consolidando a redução estrutural de blocos (`-73,6%` em `shared`) com zero I/O temporário (`-4,63 s` adicionais). |

**Conclusão do isolamento de fatores:**
1. **O Fator A (tipagem/persistência de `sk_*` nas dimensões)** é o responsável por eliminar o erro de planejamento do `Merge Join` e derrubar o tempo de CPU/ordenação de `~40 s` para `~9 s`, porém **não reduz a leitura de blocos da tabela fato (`162.397` blocos)**.
2. **O Fator B (índice parcial de cobertura `idx_fato_venda_antimicrobiano_covering`)** é a intervenção estrutural que **reduz em 73,6% a leitura de blocos compartilhados (`161.832` → `42.751` blocos)** e elimina 100% dos acessos à heap (`Heap Fetches: 0`), entregando todas as `2.122.690` linhas já juntadas em `2,80 s`.
3. **O Fator C (`work_mem = 256MB`)** remove o último gargalo remanescente (`4,86 s` de *spill to disk* nos `65 batches` do `HashAggregate`), levando o tempo total para **`4,92 s`**.

### 4.3. Por que o Plano Usa `Seq Scan` nas Dimensões e `Inner Unique: true`?

Uma leitura atenta do [`explain_after.txt`](explain_after.txt) mostra `Seq Scan` nas três tabelas dimensionais (`periodo`, `dim_municipio` e `medicamento`). Isso ocorre porque o otimizador de custos do PostgreSQL escolhe o acesso mais barato para tabelas pequenas:
* **`periodo` ocupa apenas `1` bloco de 8 KB** (`12` linhas): ler 1 página sequencialmente leva `0,04 ms` (um índice B-Tree exigiria ler pelo menos 2 páginas: raiz + folha).
* **`medicamento` ocupa `128` blocos (`1 MB`, `4.590` linhas)**: como a consulta agrupa por todos os princípios ativos sem filtrar um medicamento específico, 100% das linhas são necessárias para construir a tabela hash em memória (`473 KB`), lida sequencialmente em `2,05 ms`.
* **`dim_municipio` ocupa `68` blocos (`544 KB`, `4.898` linhas)**: o filtro `regiao = 'Sudeste'` seleciona `1.609` municípios (**32,8% da tabela**). Com seletividade de 32,8% distribuída nas 68 páginas, ler os 68 blocos contíguos via `Seq Scan` é mais rápido que saltar entre páginas de índice e tabela.
* **Papel ativo dos índices `idx_periodo_sk_tempo` e `idx_medicamento_sk_medicamento` no plano:** Embora o PostgreSQL leia `periodo` e `medicamento` via `Seq Scan` para montar as tabelas hash, ele utiliza os índices `UNIQUE` criados em `sk_tempo` e `sk_medicamento` durante o planejamento para ativar a otimização **`Inner Unique: true`** nos dois `Hash Joins` (linhas 68 e 73 de [`explain_after.txt`](explain_after.txt)), garantindo que cada linha da fato interrompa a busca no bucket hash imediatamente após o primeiro match.

---

## 5. Relatório Comparativo de Métricas (Antes vs. Depois — Mesma Query)

| Métrica / Indicador do Plano | Pré-Otimização (`explain_before.txt`) | Pós-Otimização (`explain_after.txt`) | Variação / Ganho Obtido |
| :--- | :--- | :--- | :--- |
| **Tempo Total (`Execution Time` — 1ª Execução)** | `39.968,842 ms` (~40,0 s) | **`4.920,514 ms`** (~4,9 s) | **-87,7% (`8,12x` mais rápido)** |
| **Tempo Total (`Execution Time` — `VERBOSE, SETTINGS`)** | `45.191,538 ms` (~45,2 s) | **`4.916,431 ms`** (~4,9 s) | **-89,1% (`9,19x` mais rápido)** |
| **Custo Estimado pelo Otimizador (`Total Cost`)** | `1.206.272,16` | **`248.982,14`** | **-79,4% no custo estimado** |
| **Operador de Leitura na `fato_venda_medicamento`** | `Seq Scan` (varre 6,14M linhas + filtra 1,55M) | **`Index Only Scan`** (`Heap Fetches: 0`) | **100% dos acessos à heap eliminados** |
| **Operador de Junção com `dim_medicamento`** | `Sort (external merge 245MB)` + `Merge Join` | **`Hash Join (Inner Unique)` em RAM (`473 KB`)** | **Eliminação do Sort externo e do cast `::text`** |
| **Buffers Compartilhados Totais (`shared hit + read`)** | `161.832` blocos (`1.264,3 MB`) | **`42.751` blocos (`334,0 MB`)** | **-73,6% (`-119.081` blocos / `-930,3 MB`)** |
| **Leituras Físicas/SO (`shared read`)** | `150.643` blocos (`1.176,9 MB`) | **`37.932` blocos (`296,3 MB`)** | **-74,8% de leitura de disco/SO** |
| **Buffers Temporários Lidos (`temp read`)** | `86.753` blocos (`677,8 MB`) | **`0` blocos (`0 MB`)** | **-100% (Spill to Disk eliminado)** |
| **Buffers Temporários Escritos (`temp written`)** | `147.369` blocos (`1.151,3 MB`) | **`0` blocos (`0 MB`)** | **-100% (Spill to Disk eliminado)** |
| **Partições do `HashAggregate` (`Batches`)** | `129` batches (`Disk Usage: 255.040 KB`) | **`1` batch (`Disk Usage: 0 KB`)** | **100% processado em RAM** |
| **Volume Total de I/O de Blocos (`shared + temp`)** | `395.954` blocos (**`3.093,4 MB` / `3,02 GB`**) | **`42.751` blocos (**`334,0 MB`**)** | **-89,2% de I/O total (`9,26x` menos blocos)** |

---

## 6. Projeção de Escalabilidade para o Ano Completo (12 Meses — 68,26 Milhões de Linhas)

Como destacado na Seção 1.2, o lote avaliado no container local (`202001`) contém **`6.143.427` linhas** (Janeiro/2020), enquanto os 12 arquivos mensais de 2020 somam **`68.264.756` linhas** — um fator de escala exato de **`11,11x`**.

Abaixo apresentamos o comportamento projetado para os 12 meses completos e as decisões de engenharia necessárias para manter a performance em escala anual e plurianual:

### 6.1. Projeção Quantitativa: 1 Mês (`6,14M`) vs. 12 Meses (`68,26M`)

| Componente / Métrica | Medido em 1 Mês (`202001` — `6,14M` linhas) | Projetado para 12 Meses (`202001–202012` — `68,26M` linhas) | Impacto Técnico em Escala Anual |
| :--- | :--- | :--- | :--- |
| **Tamanho da Heap (`fato_venda_medicamento`)** | `1.263 MB` (`161.683` blocos) | **`~14,03 GB`** (`~1.796.000` blocos) | Um `Seq Scan` pré-otimização leria `14 GB` do disco a cada consulta. |
| **Linhas no Filtro (`eh_antimicrobiano` + Sudeste)** | `2.122.690` linhas | **`~23.583.000` linhas** | O `Merge Join` pré-otimização despejaria **~2,7 GB** no `Sort` externo + **~2,8 GB** no `HashAggregate` (**> 34 GB** de I/O total e **7 a 9 minutos** de execução). |
| **Grupos na Agregação (`GROUP BY` mensal)** | `216.358` grupos (1 mês) | **`~2.400.000` grupos** (12 meses × ~200k combin. municipais/princípio ativo/faixa) | Em 12 meses, `2,4M` grupos exigiriam `~1,4 GB` de RAM no `HashAggregate` (voltando a fazer *spill* se `work_mem = 256MB`). |
| **Índice Covering com 3 chaves `CHAR(32)` MD5** `(sk_municipio, sk_tempo, sk_medicamento)` | `622 MB` (`4,59M` linhas indexadas) | **`~6,91 GB`** (`~51,0M` linhas indexadas) | Cada tupla do índice carrega `3 × 33 = 99 bytes` só em strings MD5. Em 12 meses, os blocos lidos do Sudeste no índice passariam de `334 MB` para **`~3,7 GB`**. |
| **Índice Covering com chaves inteiras** `(sk_municipio, id_periodo, id_medicamento)` | `339 MB` *(medido experimentalmente)* | **`~3,76 GB`** (**-45,5% menor**) | Trocar `sk_tempo CHAR(32)` e `sk_medicamento CHAR(32)` por `id_periodo INT` (4B) e `id_medicamento BIGINT` (8B) economiza **54 bytes por entrada** (`-3,15 GB` no ano). |

### 6.2. Arquitetura Recomendada para os 68,26 Milhões de Linhas (Ano Completo)

Quando os 12 meses (`68,26M` linhas) estão carregados, três ajustes complementares evitam o crescimento linear do índice de cobertura (`6,91 GB`) e o estouro de memória dos `2,4M` grupos:

1. **Particionamento Declarativo Mensal da Tabela Fato (`PARTITION BY RANGE (id_periodo)`):**
   * Dividir `fato_venda_medicamento` em 12 partições mensais mantém cada partição exatamente do tamanho medido neste benchmark (`~1,17 GB` de heap e `~310–570 MB` de índice local).
   * Consultas filtradas por mês/trimestre acionam *Partition Pruning* imediato, e o PostgreSQL 16 pode executar **`Partitionwise Aggregate`**, agregando cada mês separadamente (`~216k` grupos / `128 MB` de `work_mem` por partição) sem nunca precisar manter `2,4 milhões` de grupos simultâneos na memória.
2. **Substituição de Surrogate Keys `CHAR(32)` MD5 por Chaves Inteiras (`INT`/`BIGINT`) ou `UUID` Nativo (16 bytes):**
   * Na modelagem atual da E3, 6 colunas `CHAR(32)` na tabela fato consomem `198 bytes` por linha (**> 60% do tamanho da tabela**). Se a chave substituta for armazenada como `BIGINT` (8 bytes) ou `UUID` nativo do PostgreSQL (`16 bytes` binários em vez de `32 bytes` texto hex), a heap anual cai de `14 GB` para **`~8,2 GB`** e o índice de cobertura anual cai de `6,91 GB` para **`~3,76 GB`**.
3. **Materialized View na Camada Gold para o Painel de Gestão (`mv_consumo_antimicrobiano_mensal`):**
   * Como a carga do SNGPC é mensal em lote (batch), pré-agregar o grão `(id_periodo, sk_municipio, sk_medicamento, faixa_etaria)` reduz as `68.264.756` transações individuais do ano inteiro para **`~2,6 milhões` de linhas pré-agregadas** (**redução de 96% no volume**), permitindo que qualquer filtro do painel responda em **`< 100 ms`** com menos de `150 MB` em disco.

---

## 7. Como Reproduzir com Segurança

Com o banco carregado e o modelo dimensional populado (`make modelo-dimensional`):

```bash
# 1. Aplicar o modelo dimensional atualizado (sql/11), índices (sql/14) e VACUUM ANALYZE
make otimizar-performance

# 2. Executar o benchmark completo (gera explain_before.txt, explain_ablacao.txt e explain_after.txt)
#    O estado "antes" e as etapas intermediárias da ablação rodam dentro de transações
#    BEGIN ... ROLLBACK com SET LOCAL, de modo que o banco real nunca perde as colunas
#    geradas nem o índice de cobertura e não altera o work_mem global.
make benchmark-performance

# 3. Validar idempotência de sql/11, sql/12 e sql/14 (aplicados 2x seguidas) e INSERT nas colunas geradas
make test-scd2
```
