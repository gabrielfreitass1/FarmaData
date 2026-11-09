#!/usr/bin/env bash
# Cria (ou recria) o banco de testes da demonstração de orquestração dentro do
# container "db", com o mesmo schema de sql/ (mesma ordem do docker-compose.yml).
# Não toca no banco farmadata. Uso: bash airflow/preparar_banco_demo.sh [nome]
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1  # Git Bash no Windows: não reescrever /docker-entrypoint-initdb.d

PGU="${POSTGRES_USER:-postgres}"
PGD="${1:-farmadata_orquestracao}"

docker compose up -d --wait db
psql_() { docker compose exec -T db psql -U "$PGU" -v ON_ERROR_STOP=1 -q "$@"; }

psql_ -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${PGD}' AND pid <> pg_backend_pid();" >/dev/null
psql_ -d postgres -c "DROP DATABASE IF EXISTS ${PGD};" -c "CREATE DATABASE ${PGD};"

for f in 01_geografia_uf.sql 02_geografia_municipio.sql 03_tempo_periodo.sql 04_medicamento.sql \
         05_cid10.sql 05a_carga_cid10.sql 06_prescritor_listas.sql 07_venda_medicamento.sql \
         08_ibge_populacao_municipio.sql 09_clima_mensal_uf.sql \
         10_ibge_populacao_faixa_etaria_municipio.sql 11_dimensional_dim_municipio_scd.sql \
         12_dimensional_fato_venda.sql 13_controle_build.sql; do
  psql_ -d "$PGD" -f "/docker-entrypoint-initdb.d/${f}" >/dev/null
done
echo "banco ${PGD} pronto"
