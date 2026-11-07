# Teste manual — Modelo Dimensional & SCD2 (issue #24)

**Data:** 2026-11-07
**Ambiente:** container `farmadata_db` (postgres:16-alpine), via `docker compose`, porta mapeada em `55432` (a `5432` padrão estava ocupada por outro projeto nesta máquina — `anatoquizup-postgres`).

Resumo: **deu certo**, com um bug real encontrado e corrigido no meio do caminho (detalhado na seção 4).

---

## 1. Teste automatizado (`make test-scd2`)

```
$ POSTGRES_PORT=55432 make test-scd2
```

```
[1] Município de teste: insere e aplica SCD2 (1a versão)
dim_municipio após 1a carga: Vila Antiga|1900-01-01|NULL|true

[2] Alteração territorial: IBGE renomeia o município; reaplica SCD2
dim_municipio após renomeação (todas as versões, histórico preservado):
Vila Antiga|1900-01-01|2024-06-15|false
Vila Nova|2024-06-15|NULL|true

=== RESULTADO: versão antiga preservada (is_current=f, valid_to fechado); nova versão corrente com sk_municipio distinta ✓ ===

[3] Duas alterações no mesmo município no mesmo dia (mesma valid_from): não deve colidir
dim_municipio após 2 mudanças no mesmo dia (colapsa para o estado final do dia):
Vila Antiga|1900-01-01|2024-06-15|false
Vila Nova|2024-06-15|2024-06-20|false
Vila Nova|2024-06-20|NULL|true

=== RESULTADO: duas mudanças no mesmo dia não colidem na surrogate key; estado final correto ✓ ===
```

**Passou.** Evidência completa (saída real do script) em [`docs/evidencias/scd2.txt`](scd2.txt).

---

## 2. Fluxo manual completo contra o banco real (`farmadata`)

Container já existia com volume (`pgdata`) de uma carga anterior — Postgres só roda os scripts de `docker-entrypoint-initdb.d/` numa inicialização de volume vazio, então os arquivos `sql/11` e `sql/12` (novos nesta branch) foram aplicados manualmente e sem perda de dados:

```
$ docker compose exec -T db psql -U postgres -d farmadata -f /docker-entrypoint-initdb.d/11_dimensional_dim_municipio_scd.sql
CREATE TABLE
COMMENT
CREATE INDEX
CREATE INDEX
CREATE FUNCTION
COMMENT
CREATE VIEW ×5

$ docker compose exec -T db psql -U postgres -d farmadata -f /docker-entrypoint-initdb.d/12_dimensional_fato_venda.sql
CREATE TABLE
COMMENT
CREATE INDEX ×3
CREATE FUNCTION
COMMENT
```

### 2.1 `make modelo-dimensional` sobre o dataset real

```
$ POSTGRES_PORT=55432 make modelo-dimensional

 municipios_novos | municipios_versionados
------------------+------------------------
             5130 |                      0

 linhas_carregadas
-------------------
         112991859

40:32,08 total (tempo de parede)
```

Levou **~40 minutos** para 112.991.859 linhas — volume bem maior que o recorte anual estimado no ADR-001 (~18M), então este `farmadata` tinha vários meses/anos carregados. Confirmei via `docker stats` que o container ficou a ~100% de CPU o tempo todo (não travou, só é uma junção custosa: nested loop + memoize + 6 `md5()` por linha, concorrendo CPU com outros 3 containers Postgres rodando na mesma máquina).

### 2.2 Conferência de grão e integridade

```sql
SELECT count(*) FROM venda_medicamento;        -- 112991859
SELECT count(*) FROM fato_venda_medicamento;   -- 112991859  ✓ bate exatamente
SELECT count(*) FROM dim_municipio;            -- 5130       ✓ = count(municipio)
SELECT count(*) FROM dim_municipio WHERE is_current; -- 5130 ✓ 1 corrente por município
SELECT count(*) FROM fato_venda_medicamento WHERE sk_municipio IS NULL; -- 0 ✓ nenhuma venda órfã
```

Amostra da fato com as surrogate keys resolvidas:

```
 id_venda |             sk_tempo             |           sk_municipio           |          sk_medicamento          | quantidade_vendida | data_venda
----------+----------------------------------+----------------------------------+----------------------------------+---------------------+------------
        1 | 53b152a96afe04ea93ebf656b1fb748a | d787e6946125c097dc0e376b6338d95c | ea3297f56bdf619a234ddaa9929614dc |               1.000 | 2020-01-01
```

**Resultado:** grão idêntico à fonte, nenhuma venda sem dimensão resolvida. ✓

---

## 3. Teste manual de alteração territorial no dataset real

Município escolhido: `id_municipio = 2566` (CAPÃO DA CANOA, RS).

```sql
UPDATE municipio SET nome_municipio = 'CAPAO DA CANOA (RENOMEADO IBGE)' WHERE id_municipio = 2566;
SELECT aplicar_scd2_municipio(DATE '2026-11-07');
```

```
nome_municipio                   | sigla_uf | valid_from | valid_to   | is_current | sk_municipio
CAPÃO DA CANOA                   | RS       | 1900-01-01 | 2026-11-07 | false      | 6f36089b96587469f267e4283ade6ad5
CAPAO DA CANOA (RENOMEADO IBGE)  | RS       | 2026-11-07 |            | true       | 2f224329b4e1d3e17bc0ec16289c83db
```

Versão antiga preservada (`is_current=false`, `valid_to` fechado), nova versão corrente com `sk_municipio` distinta — exatamente o comportamento do SCD2 exigido pela issue. ✓

(O dado de teste foi revertido ao final — ver seção 5.)

---

## 4. Bug encontrado e corrigido

Ao tentar **reverter** a mudança de teste (`UPDATE municipio` de volta ao nome original + `aplicar_scd2_municipio()` de novo, **no mesmo dia**), a função quebrou:

```
ERROR:  duplicate key value violates unique constraint "dim_municipio_pkey"
DETAIL:  Key (sk_municipio)=(2f224329b4e1d3e17bc0ec16289c83db) already exists.
```

**Causa raiz:** `sk_municipio = md5(id_municipio || valid_from)`. Se a função é chamada duas vezes no mesmo dia para o mesmo município (duas mudanças reais no mesmo dia, ou — como aqui — mudar e reverter), a segunda tentativa de abrir uma versão nova gera a **mesma** `valid_from` (hoje) e portanto a **mesma** `sk_municipio` da versão que acabou de ser fechada — violação de chave primária.

**Correção** (`sql/11_dimensional_dim_municipio_scd.sql`):
- Adicionado `ON CONFLICT (sk_municipio) DO UPDATE` no INSERT final: se já existe uma versão para esse município com esse `valid_from` (= mudança no mesmo dia), a função colapsa para o estado mais recente do dia em vez de tentar inserir uma segunda linha.
- Removido um `JOIN` redundante (`dm_fechada`) que, combinado com múltiplas linhas históricas antigas compartilhando o mesmo `valid_to`, causava duplicação de linhas na própria consulta de origem do INSERT (erro adicional: "ON CONFLICT DO UPDATE command cannot affect row a second time"). A condição `NOT EXISTS (linha corrente)` já era suficiente por si só.
- Marcado como `ponytail:` o limite deliberado: `valid_from`/`valid_to` são `DATE`, não `TIMESTAMP` — duas mudanças reais no mesmo município no mesmo dia colapsam na última. Upgrade path documentado no comentário do código, caso granularidade por timestamp seja necessária.

**Validação do fix:** reproduzi o cenário exato (renomear → aplicar → reverter → aplicar, mesmo dia) depois da correção — funcionou. Também adicionei esse cenário como passo `[3]` permanente em `test_scd2_municipio.sh`, que passa (seção 1 acima).

Commit: `fix: evita colisão de surrogate key em dim_municipio quando há 2 mudanças no mesmo dia`.

---

## 5. Limpeza — dataset real restaurado

O município de teste (2566) foi revertido ao estado original; nenhuma venda referencia a versão de demonstração (todas as vendas são de 2020, antes da data simulada), então a remoção foi segura (sem violar FK de `fato_venda_medicamento`):

```sql
DELETE FROM dim_municipio WHERE sk_municipio = '2f224329b4e1d3e17bc0ec16289c83db';
UPDATE dim_municipio SET valid_to = NULL, is_current = TRUE
  WHERE sk_municipio = '6f36089b96587469f267e4283ade6ad5';
```

Conferência final:

```
SELECT count(*) FROM dim_municipio;             -- 5130
SELECT count(*) FROM dim_municipio WHERE is_current; -- 5130
SELECT count(*) FROM fato_venda_medicamento;     -- 112991859 (inalterado)
```

Container de teste (`farmadata_db` na porta `55432`) derrubado ao final (`docker compose down db`) — nenhum serviço ficou rodando.

---

## 6. Nota operacional (achado durante o teste, não é bug de código)

Neste ambiente, o bind mount de `./sql/*.sql` para `/docker-entrypoint-initdb.d/` **não refletiu edições ao vivo** — depois de editar `sql/11_dimensional_dim_municipio_scd.sql` com o container já rodando, `docker compose exec db grep ...` continuava mostrando o conteúdo antigo até um `docker compose down db && docker compose up -d db` (recria o container; o volume `pgdata` não é afetado). Se outro ambiente Docker apresentar o mesmo comportamento, um `down`/`up` do serviço `db` resolve.
