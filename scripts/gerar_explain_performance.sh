#!/usr/bin/env bash
# Issue #28 — reproduz os planos de execução antes e depois das otimizações da
# camada de consumo (esquema estrela), sempre com EXATAMENTE a mesma consulta SQL:
#
#   docs/performance/explain_before.txt   estado anterior às otimizações
#   docs/performance/explain_after.txt    estado otimizado
#
# Segurança: o banco real nunca fica no estado "antes". O "antes" é montado
# dentro de BEGIN ... ROLLBACK (o Postgres desfaz DDL no ROLLBACK, e uma falha
# no meio também aborta a transação). work_mem e jit são ajustados só na sessão
# do benchmark (SET / SET LOCAL), nunca via ALTER DATABASE.
#
# Ressalvas:
# 1. CREATE INDEX (em sql/14) bloqueia escritas em fato_venda_medicamento enquanto
#    roda — não execute durante uma carga.
# 2. VACUUM precisa ficar fora da transação e mantém o Visibility Map atualizado
#    para o Index Only Scan com Heap Fetches: 0.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PGU="${POSTGRES_USER:-postgres}"
PGD="${POSTGRES_DB:-farmadata}"
OUT=docs/performance
mkdir -p "$OUT"

# -X ignora ~/.psqlrc; -q suprime as tags de comando (BEGIN, SET, DROP, ROLLBACK),
# deixando no arquivo apenas a saída do EXPLAIN.
Q() {
  docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db \
    psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -X -q "$@"
}

QUERY_SQL="EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
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
LIMIT 50;"

echo "=== [1/3] Preparando: aplica modelo (sql/11), índices (sql/14) e atualiza o Visibility Map ==="
Q < sql/11_dimensional_dim_municipio_scd.sql
Q < sql/14_otimizacao_performance.sql
Q -c "SET max_parallel_maintenance_workers = 0;" -c "VACUUM fato_venda_medicamento;"

echo "=== [2/3] ANTES: reverte dentro de uma transação, mede e desfaz -> $OUT/explain_before.txt ==="
Q > "$OUT/explain_before.txt" <<SQL
BEGIN;
SET LOCAL work_mem = '4MB';
SET LOCAL jit = on;
ALTER FUNCTION sk_hash(TEXT, ANYELEMENT) PARALLEL UNSAFE;
DROP INDEX IF EXISTS idx_fato_venda_antimicrobiano_covering;
DROP VIEW IF EXISTS dim_tempo;
DROP VIEW IF EXISTS dim_medicamento;
ALTER TABLE periodo DROP COLUMN sk_tempo;
ALTER TABLE medicamento DROP COLUMN sk_medicamento;
CREATE VIEW dim_tempo AS SELECT sk_hash('tempo', id_periodo) AS sk_tempo, id_periodo, ano, mes, nome_mes, trimestre, semestre, data_inicio, data_fim FROM periodo;
CREATE VIEW dim_medicamento AS SELECT sk_hash('medicamento', id_medicamento) AS sk_medicamento, id_medicamento, principio_ativo, descricao_apresentacao FROM medicamento;
ANALYZE periodo;
ANALYZE medicamento;
${QUERY_SQL}
ROLLBACK;
SQL

echo "=== [3/3] DEPOIS: banco no estado otimizado, com work_mem só nesta sessão -> $OUT/explain_after.txt ==="
Q > "$OUT/explain_after.txt" <<SQL
SET work_mem = '256MB';
SET jit = off;
${QUERY_SQL}
SQL

echo "=== Concluído: $OUT/explain_before.txt e $OUT/explain_after.txt ==="
