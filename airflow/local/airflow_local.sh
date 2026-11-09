#!/usr/bin/env bash
# Sobe o Airflow + um PostgreSQL 16 local SEM Docker e SEM root (Linux/WSL).
# Alternativa ao Docker. As evidências de docs/orchestration/ foram geradas no
# Docker (make airflow-demo); prefira-o quando disponível.
#
# Pré-requisitos: uv (https://docs.astral.sh/uv/) e Node.js 20 no PATH
# (ou FARMADATA_NODE apontando para o binário).
#
# Uso:
#   bash airflow/local/airflow_local.sh setup   # venv + Airflow + Postgres + schema
#   bash airflow/local/airflow_local.sh start   # Postgres + scheduler + webserver (porta 8080)
#   bash airflow/local/airflow_local.sh stop
#   bash airflow/local/airflow_local.sh env     # imprime os exports p/ usar a CLI do airflow
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${FARMADATA_AIRFLOW_BASE:-$HOME/farmadata-airflow}"
VENV="$BASE/venv"
PGDATA="$BASE/pgdata"
PGPORT="${FARMADATA_PGPORT:-5433}"
AIRFLOW_VERSION=2.10.5

pgbin() { echo "$("$VENV/bin/python" -c 'import pgserver,os;print(os.path.dirname(pgserver.__file__))')/pginstall/bin"; }

ambiente() {
  cat <<EOF
export AIRFLOW_HOME="$BASE/home"
export AIRFLOW__CORE__DAGS_FOLDER="$REPO/airflow/dags"
export AIRFLOW__CORE__LOAD_EXAMPLES=False
export AIRFLOW__CORE__EXECUTOR=LocalExecutor
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="postgresql+psycopg2://postgres@127.0.0.1:$PGPORT/airflow"
export AIRFLOW__SCHEDULER__MIN_FILE_PROCESS_INTERVAL=10
export AIRFLOW__WEBSERVER__EXPOSE_CONFIG=False
export FARMADATA_DIR="$REPO"
export FARMADATA_DATABASE_URL="postgres://postgres@127.0.0.1:$PGPORT/farmadata"
export FARMADATA_SNGPC_DIR="\${FARMADATA_SNGPC_DIR-$REPO/scripts/fixtures/orquestracao}"
export FARMADATA_NODE="\${FARMADATA_NODE:-node}"
export PATH="$VENV/bin:\$PATH"
EOF
}

psql_() { "$(pgbin)/psql" -h 127.0.0.1 -p "$PGPORT" -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

pg_start() {
  "$(pgbin)/pg_ctl" -D "$PGDATA" -l "$BASE/postgres.log" -o "-p $PGPORT -k /tmp" -w status >/dev/null 2>&1 \
    || "$(pgbin)/pg_ctl" -D "$PGDATA" -l "$BASE/postgres.log" -o "-p $PGPORT -k /tmp" -w start
}

case "${1:-}" in
  setup)
    mkdir -p "$BASE"
    [ -x "$VENV/bin/python" ] || uv venv -q -p 3.12 "$VENV"
    VIRTUAL_ENV="$VENV" uv pip install -q "apache-airflow==$AIRFLOW_VERSION" "psycopg[binary]" psycopg2-binary pgserver \
      --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-$AIRFLOW_VERSION/constraints-3.12.txt"
    [ -d "$PGDATA" ] || "$(pgbin)/initdb" -D "$PGDATA" -U postgres -A trust -E UTF8 --locale=C.UTF-8 >/dev/null
    pg_start
    psql_ -d postgres -c "DROP DATABASE IF EXISTS farmadata" -c "CREATE DATABASE farmadata" \
      -c "DROP DATABASE IF EXISTS airflow" -c "CREATE DATABASE airflow"
    # Mesma ordem do docker-entrypoint-initdb.d em docker-compose.yml
    for f in 01_geografia_uf 02_geografia_municipio 03_tempo_periodo 04_medicamento 05_cid10 \
             05_carga_catalogo_cid10 06_prescritor_listas 07_venda_medicamento 08_ibge_populacao_municipio \
             09_clima_mensal_uf 10_ibge_populacao_faixa_etaria_municipio 11_dimensional_dim_municipio_scd \
             12_dimensional_fato_venda 13_controle_build; do
      psql_ -d farmadata -f "$REPO/sql/$f.sql" >/dev/null
    done
    (cd "$REPO" && npm install --omit=dev --no-audit --no-fund --silent)
    eval "$(ambiente)"
    mkdir -p "$AIRFLOW_HOME"
    # Ambiente local de desenvolvimento: UI sem login (papel Admin para anônimo).
    printf 'AUTH_ROLE_PUBLIC = "Admin"\n' > "$AIRFLOW_HOME/webserver_config.py"
    airflow db migrate >/dev/null
    echo "setup ok — rode: bash $0 start"
    ;;
  start)
    pg_start
    eval "$(ambiente)"
    nohup airflow scheduler >"$BASE/scheduler.out" 2>&1 &
    echo $! >"$BASE/scheduler.pid"
    nohup airflow webserver -p 8080 >"$BASE/webserver.out" 2>&1 &
    echo $! >"$BASE/webserver.pid"
    echo "Airflow em http://localhost:8080 (logs em $BASE/*.out)"
    ;;
  stop)
    for p in webserver scheduler; do
      [ -f "$BASE/$p.pid" ] && kill "$(cat "$BASE/$p.pid")" 2>/dev/null || true
      rm -f "$BASE/$p.pid"
    done
    pkill -f "airflow (scheduler|webserver)" 2>/dev/null || true
    "$(pgbin)/pg_ctl" -D "$PGDATA" -m fast stop || true
    ;;
  env)
    ambiente
    ;;
  *)
    sed -n '2,13p' "$0"; exit 2 ;;
esac
