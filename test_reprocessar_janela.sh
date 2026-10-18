#!/usr/bin/env bash
# Janeiro já carregado. Fevereiro chega com uma venda de janeiro.
# Recarregar fevereiro substitui só as linhas desse CSV.
# A linha de janeiro que já estava no banco permanece, sem duplicar a atrasada.
# Banco farmadata_sim_atraso: criado aqui e removido ao final.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PGU="${POSTGRES_USER:-postgres}"
PGP="${POSTGRES_PASSWORD:-postgres}"
PGD="farmadata_sim_atraso"
ARQ_JAN="EDA_Industrializados_202001.csv"
ARQ_FEV="EDA_Industrializados_202002.csv"
FIXTURE="scripts/fixtures/dado_atrasado"

mkdir -p docs/evidencias
exec > >(tee docs/evidencias/reprocessamento_janela.txt) 2>&1

Q() { docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -tA -c "$1"; }

limpar() {
  docker compose exec -T db psql -U "$PGU" -d postgres -v ON_ERROR_STOP=1 -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${PGD}' AND pid <> pg_backend_pid();" \
    >/dev/null 2>&1 || true
  docker compose exec -T db psql -U "$PGU" -d postgres -c "DROP DATABASE IF EXISTS ${PGD};" \
    >/dev/null 2>&1 || true
}
trap limpar EXIT

carga() { # $1 = meses (01 ou 02), $2 = SNGPC_FORCE (0 ou 1)
  docker compose run --rm -T \
    -e DATABASE_URL="postgres://${PGU}:${PGP}@farmadata_db:5432/${PGD}" \
    -e SNGPC_MESES="$1" \
    -e SNGPC_FORCE="$2" \
    -e SNGPC_DIR="/app/${FIXTURE}" \
    -e ANO_RECORTE=2020 \
    carga sh -c "npm install --omit=dev --silent pg-copy-streams >/dev/null 2>&1 && node scripts/carregar_sngpc.js"
}

snap() {
  Q "SELECT id_periodo || '|' || data_venda || '|' || quantidade_vendida || '|' || arquivo_origem FROM venda_medicamento ORDER BY arquivo_origem, id_periodo, quantidade_vendida;"
}

janela_jan() {
  Q "SELECT count(*) || '|' || coalesce(sum(quantidade_vendida),0) FROM venda_medicamento WHERE id_periodo = 202001;"
}

arquivo_jan() {
  Q "SELECT count(*) || '|' || coalesce(sum(quantidade_vendida),0) FROM venda_medicamento WHERE arquivo_origem = '${ARQ_JAN}';"
}

echo "=== Reprocessamento da janela 202001 — $(date '+%Y-%m-%dT%H:%M:%S%z') ==="
echo "Já carregado: ${ARQ_JAN} (venda 2020-01, quantidade 10)"
echo "Chegada: ${ARQ_FEV} (venda 2020-01 quantidade 1, venda 2020-02 quantidade 2, venda 2019-12 quantidade 3)"
echo

[ -f "${FIXTURE}/${ARQ_JAN}" ] || { echo "Fixture ausente: ${FIXTURE}/${ARQ_JAN}"; exit 2; }
[ -f "${FIXTURE}/${ARQ_FEV}" ] || { echo "Fixture ausente: ${FIXTURE}/${ARQ_FEV}"; exit 2; }

docker compose up -d --wait db

docker compose exec -T db psql -U "$PGU" -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${PGD};"
docker compose exec -T db psql -U "$PGU" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${PGD};"

for f in \
  01_geografia_uf.sql \
  02_geografia_municipio.sql \
  03_tempo_periodo.sql \
  04_medicamento.sql \
  05_cid10.sql \
  06_prescritor_listas.sql \
  07_venda_medicamento.sql
do
  docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 \
    -f "/docker-entrypoint-initdb.d/${f}" >/dev/null
done

echo "[1] Carga de janeiro"
carga 01 0
echo "janela 202001 (linhas|soma): $(janela_jan)"
echo "arquivo janeiro (linhas|soma): $(arquivo_jan)"

echo
echo "[2] Carga de fevereiro, com venda de janeiro"
carga 02 0
DEPOIS="$(snap)"
echo "venda_medicamento (id_periodo | data_venda | quantidade | arquivo_origem)"
echo "$DEPOIS"
echo "janela 202001 (linhas|soma): $(janela_jan)"
echo "arquivo janeiro (linhas|soma): $(arquivo_jan)"

echo
echo "[3] Reexecução de fevereiro sem FORCE (esperado: SKIP)"
carga 02 0
SKIP_SNAP="$(snap)"

echo
echo "[4] Recarga de fevereiro com SNGPC_FORCE=1 (esperado: troca só esse arquivo)"
carga 02 1
FORCE_SNAP="$(snap)"
echo "venda_medicamento (id_periodo | data_venda | quantidade | arquivo_origem)"
echo "$FORCE_SNAP"
echo "janela 202001 (linhas|soma): $(janela_jan)"
echo "arquivo janeiro (linhas|soma): $(arquivo_jan)"

ESPERADO="202001|2020-01-01|10.000|${ARQ_JAN}
202001|2020-01-01|1.000|${ARQ_FEV}
202002|2020-02-01|2.000|${ARQ_FEV}"

echo
if [ "$DEPOIS" = "$ESPERADO" ] && [ "$SKIP_SNAP" = "$ESPERADO" ] && [ "$FORCE_SNAP" = "$ESPERADO" ] \
  && [ "$(janela_jan)" = "2|11.000" ] && [ "$(arquivo_jan)" = "1|10.000" ]; then
  echo "=== RESULTADO: janeiro já carregado permaneceu; a venda atrasada não duplicou ✓ ==="
else
  echo "=== RESULTADO: divergência ==="
  echo "esperado:"
  echo "$ESPERADO"
  echo "janela 202001: $(janela_jan) (esperado 2|11.000)"
  echo "arquivo janeiro: $(arquivo_jan) (esperado 1|10.000)"
  exit 1
fi
