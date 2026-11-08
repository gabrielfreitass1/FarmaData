#!/usr/bin/env bash
# Reproduz os planos de execução antes e depois das otimizações da Issue #28,
# salvando as saídas em docs/performance/explain_before.txt e explain_after.txt.
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

mkdir -p docs/performance

Q() {
  docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 "$@"
}

echo "=== [1/4] Removendo índices e configurações de otimização para medir o baseline (BEFORE) ==="
Q -c "
DROP INDEX IF EXISTS idx_fato_venda_antimicrobiano_covering;
DROP INDEX IF EXISTS idx_fato_venda_periodo_brin;
DROP INDEX IF EXISTS idx_dim_municipio_regiao_sk;
DROP INDEX IF EXISTS idx_periodo_sk_tempo_bpchar;
DROP INDEX IF EXISTS idx_periodo_sk_tempo_text;
DROP INDEX IF EXISTS idx_medicamento_sk_med_bpchar;
DROP INDEX IF EXISTS idx_medicamento_sk_med_text;
ALTER FUNCTION sk_hash(TEXT, ANYELEMENT) PARALLEL UNSAFE;
ALTER DATABASE ${PGD} RESET work_mem;
ALTER DATABASE ${PGD} RESET jit;
ANALYZE periodo;
ANALYZE medicamento;
ANALYZE dim_municipio;
ANALYZE fato_venda_medicamento;
"

echo "=== [2/4] Executando EXPLAIN (ANALYZE, BUFFERS) PRÉ-OTIMIZAÇÃO -> docs/performance/explain_before.txt ==="
Q -c "
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
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
" > docs/performance/explain_before.txt

echo "=== [3/4] Aplicando sql/14_otimizacao_performance.sql e VACUUM ANALYZE ==="
Q < sql/14_otimizacao_performance.sql
Q -c "VACUUM ANALYZE fato_venda_medicamento;"
Q -c "VACUUM ANALYZE dim_municipio;"
Q -c "VACUUM ANALYZE medicamento;"
Q -c "VACUUM ANALYZE periodo;"

echo "=== [4/4] Executando EXPLAIN (ANALYZE, BUFFERS) PÓS-OTIMIZAÇÃO -> docs/performance/explain_after.txt ==="
Q -c "
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
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
JOIN dim_tempo t        ON t.id_periodo = f.id_periodo
JOIN dim_municipio dm   ON dm.sk_municipio = f.sk_municipio
JOIN dim_medicamento m  ON m.id_medicamento = f.id_medicamento
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
" > docs/performance/explain_after.txt

echo "=== Concluído! Planos salvos em docs/performance/explain_before.txt e docs/performance/explain_after.txt ==="
