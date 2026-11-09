#!/usr/bin/env bash
# Prova que um atraso induzido dispara WARN e ERRO (gera docs/evidencias/freshness.txt).
set -euo pipefail
cd "$(dirname "$0")"
# Com o Airflow de pé (docker-compose.airflow.yml), o compose avisa sobre containers
# "órfãos" e o aviso vazaria para a evidência. Só silencia o aviso; não remove nada.
export COMPOSE_IGNORE_ORPHANS=1
PGU="${POSTGRES_USER:-postgres}"
PGD="farmadata_sim_freshness"
T="fato_teste"
mkdir -p docs/evidencias
exec > >(tee docs/evidencias/freshness.txt) 2>&1

P() { docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -tA -c "$1" >/dev/null; }
limpar() {
  docker compose exec -T db psql -U "$PGU" -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${PGD}' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  docker compose exec -T db psql -U "$PGU" -d postgres -c "DROP DATABASE IF EXISTS ${PGD};" >/dev/null 2>&1 || true
}
trap limpar EXIT
esperar() {  # $1 = código esperado
  set +e; FRESHNESS_DB="$PGD" bash scripts/checar_freshness.sh "$T"; rc=$?; set -e
  if [ "$rc" != "$1" ]; then echo "   ✗ FALHA: esperava código $1, veio $rc"; exit 1; fi
  echo "   ✓ código de saída $rc, como esperado"
}

echo "=== Teste de freshness — $(date -Is) ==="
docker compose up -d --wait db
docker compose exec -T db psql -U "$PGU" -d postgres -c "DROP DATABASE IF EXISTS ${PGD};" >/dev/null
docker compose exec -T db psql -U "$PGU" -d postgres -c "CREATE DATABASE ${PGD};" >/dev/null
docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -q < sql/13_controle_build.sql
P "CREATE TABLE carga_arquivo (arquivo TEXT PRIMARY KEY, linhas_inseridas BIGINT, carregado_em TIMESTAMPTZ NOT NULL DEFAULT now());"

echo "[1] Tabela nunca construída (esperado: ERRO)"
P "INSERT INTO carga_arquivo VALUES ('EDA_teste_202001.csv', 100, now());"
esperar 2

echo "[2] Tabela construída depois da carga (esperado: OK)"
P "SELECT registrar_build('${T}', 100);"
esperar 0

echo "[3] Carga nova há 30h, tabela construída antes dela (esperado: WARN)"
P "DELETE FROM carga_arquivo; DELETE FROM controle_build;"
P "INSERT INTO controle_build (tabela, construido_em, linhas) VALUES ('${T}', now() - interval '40 hours', 100);"
P "INSERT INTO carga_arquivo VALUES ('EDA_teste_202002.csv', 100, now() - interval '30 hours');"
esperar 1

echo "[4] Mesma carga pendente há 50h (esperado: ERRO)"
P "UPDATE carga_arquivo SET carregado_em = now() - interval '50 hours';"
P "UPDATE controle_build SET construido_em = now() - interval '60 hours';"
esperar 2

echo "[5] Reconstrução após a mitigação (esperado: OK)"
P "SELECT registrar_build('${T}', 200);"
esperar 0

echo "=== RESULTADO: atraso induzido dispara WARN e ERRO; reconstruir volta a OK ✓ ==="