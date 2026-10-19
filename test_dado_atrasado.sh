#!/usr/bin/env bash
# Roda o carregador SNGPC sobre um CSV de fevereiro/2020 com três linhas:
# venda de 202001, venda de 202002 e venda de 201912.
# O banco farmadata_sim_atraso é criado para essa execução e removido ao final.
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
ARQ="EDA_Industrializados_202002.csv"
FIXTURE="scripts/fixtures/dado_atrasado"

mkdir -p docs/evidencias
exec > >(tee docs/evidencias/dado_atrasado.txt) 2>&1

Q() { docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -tA -c "$1"; }

limpar() {
  docker compose exec -T db psql -U "$PGU" -d postgres -v ON_ERROR_STOP=1 -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${PGD}' AND pid <> pg_backend_pid();" \
    >/dev/null 2>&1 || true
  docker compose exec -T db psql -U "$PGU" -d postgres -c "DROP DATABASE IF EXISTS ${PGD};" \
    >/dev/null 2>&1 || true
}
trap limpar EXIT

echo "=== Dado atrasado — ${ARQ} — $(date '+%Y-%m-%dT%H:%M:%S%z') ==="
echo "CSV: ${FIXTURE}/${ARQ}"
echo "  venda 2020-01, quantidade 1 — mês anterior ao arquivo"
echo "  venda 2020-02, quantidade 2 — mesmo mês do arquivo"
echo "  venda 2019-12, quantidade 3 — fora de ANO_RECORTE"
echo

[ -f "${FIXTURE}/${ARQ}" ] || { echo "Fixture ausente: ${FIXTURE}/${ARQ}"; exit 2; }

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

echo "[1] Carga"
docker compose run --rm -T \
  -e DATABASE_URL="postgres://${PGU}:${PGP}@farmadata_db:5432/${PGD}" \
  -e SNGPC_MESES=02 \
  -e SNGPC_DIR="/app/${FIXTURE}" \
  -e ANO_RECORTE=2020 \
  carga sh -c "npm install --omit=dev --silent pg-copy-streams >/dev/null 2>&1 && node scripts/carregar_sngpc.js"

echo
echo "[2] venda_medicamento (id_periodo | data_venda | quantidade | arquivo_origem)"
VENDAS="$(Q "SELECT id_periodo || '|' || data_venda || '|' || quantidade_vendida || '|' || arquivo_origem FROM venda_medicamento ORDER BY id_periodo, quantidade_vendida;")"
echo "$VENDAS"

echo
echo "[3] carga_arquivo (lidas | inseridas | rejeitadas | fora_do_recorte | realocadas | realocadas_202001)"
CONTROLE="$(Q "SELECT linhas_lidas || '|' || linhas_inseridas || '|' || linhas_rejeitadas || '|' || COALESCE(motivos_rejeicao->>'periodo_fora_do_recorte','0') || '|' || COALESCE(eventos_atrasados->>'realocado_para_periodo_da_venda','0') || '|' || COALESCE(eventos_atrasados->'por_periodo_da_venda'->>'202001','0') FROM carga_arquivo WHERE arquivo='${ARQ}';")"
echo "$CONTROLE"
echo
echo "motivos_rejeicao=$(Q "SELECT motivos_rejeicao FROM carga_arquivo WHERE arquivo='${ARQ}';")"
echo "eventos_atrasados=$(Q "SELECT eventos_atrasados FROM carga_arquivo WHERE arquivo='${ARQ}';")"

ESPERADO_VENDAS="202001|2020-01-01|1.000|${ARQ}
202002|2020-02-01|2.000|${ARQ}"
ESPERADO_CONTROLE="3|2|1|1|1|1"

echo
if [ "$VENDAS" = "$ESPERADO_VENDAS" ] && [ "$CONTROLE" = "$ESPERADO_CONTROLE" ]; then
  echo "=== RESULTADO: venda de janeiro entrou em 202001; 201912 foi rejeitada ✓ ==="
else
  echo "=== RESULTADO: divergência ==="
  echo "esperado vendas:"
  echo "$ESPERADO_VENDAS"
  echo "esperado controle: $ESPERADO_CONTROLE"
  exit 1
fi
