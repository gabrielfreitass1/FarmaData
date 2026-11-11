#!/usr/bin/env bash
# Prova o versionamento SCD Tipo 2 de dim_municipio: primeira carga abre a
# versão vigente; uma alteração territorial (renomeação) fecha a versão
# antiga (valid_to/is_current=false, preservada) e abre uma nova corrente.
# O banco farmadata_sim_scd2 é criado para essa execução e removido ao final.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PGU="${POSTGRES_USER:-postgres}"
PGD="farmadata_sim_scd2"
ID_MUNICIPIO=999001

mkdir -p docs/evidencias
exec > >(tee docs/evidencias/scd2.txt) 2>&1

Q() { docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -q -tA -c "$1"; }

limpar() {
  docker compose exec -T db psql -U "$PGU" -d postgres -v ON_ERROR_STOP=1 -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${PGD}' AND pid <> pg_backend_pid();" \
    >/dev/null 2>&1 || true
  docker compose exec -T db psql -U "$PGU" -d postgres -c "DROP DATABASE IF EXISTS ${PGD};" \
    >/dev/null 2>&1 || true
}
trap limpar EXIT

echo "=== SCD2 dim_municipio — $(date '+%Y-%m-%dT%H:%M:%S%z') ==="
echo

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
  07_venda_medicamento.sql \
  11_dimensional_dim_municipio_scd.sql \
  12_dimensional_fato_venda.sql \
  13_controle_build.sql
do
  docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 \
    -f "/docker-entrypoint-initdb.d/${f}" >/dev/null
done

# Idempotência da camada dimensional (issue #28): sql/11 (sk_* persistida em
# periodo/medicamento + views), sql/12, sql/13 e sql/14 (índices) reaplicados
# duas vezes sobre o banco já criado, inclusive sql/11 depois de sql/14.
for rodada in 1 2; do
  for f in 11_dimensional_dim_municipio_scd.sql 12_dimensional_fato_venda.sql 13_controle_build.sql 14_otimizacao_performance.sql; do
    docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db \
      psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -q < "sql/$f"
  done
done
echo "[idempotência] sql/11, 12, 13 e 14 aplicados duas vezes sem erro ✓"
echo "  dim_tempo.sk_tempo: $(Q "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'dim_tempo'::regclass AND attname = 'sk_tempo';")"
echo "  dim_medicamento.sk_medicamento: $(Q "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'dim_medicamento'::regclass AND attname = 'sk_medicamento';")"

# Coluna gerada não aceita valor explícito: a carga (carregar_sngpc.js) insere
# em medicamento/periodo com lista de colunas, então a sk_* é gerada sozinha.
MED="$(Q "INSERT INTO medicamento (principio_ativo, descricao_apresentacao) VALUES ('TESTE_SK', 'TESTE_SK') RETURNING id_medicamento || '|' || length(sk_medicamento) || '|' || (sk_medicamento = md5('medicamento|' || id_medicamento));")"
PER="$(Q "INSERT INTO periodo (id_periodo, ano, mes, nome_mes, trimestre, semestre, data_inicio, data_fim) VALUES (209901, 2099, 1, 'Janeiro', 1, 1, '2099-01-01', '2099-01-31') RETURNING length(sk_tempo) || '|' || (sk_tempo = md5('tempo|209901'));")"
echo "  INSERT medicamento (lista de colunas) -> id|len(sk)|sk=md5: ${MED}"
echo "  INSERT periodo (lista de colunas)     -> len(sk)|sk=md5: ${PER}"
if [[ "$MED" == *"|32|true" ]] && [ "$PER" = "32|true" ]; then
  echo "[colunas geradas] sk_medicamento e sk_tempo gerados automaticamente ✓"
else
  echo "[colunas geradas] divergência"
  exit 1
fi
echo

echo "[1] Município de teste: insere e aplica SCD2 (1a versão)"
Q "INSERT INTO municipio (id_municipio, nome_municipio, sigla_uf, codigo_ibge) VALUES (${ID_MUNICIPIO}, 'Vila Antiga', 'GO', 5200001) ON CONFLICT DO NOTHING;" >/dev/null
Q "SELECT aplicar_scd2_municipio();" >/dev/null

V1="$(Q "SELECT nome_municipio || '|' || valid_from || '|' || COALESCE(valid_to::text,'NULL') || '|' || is_current FROM dim_municipio WHERE id_municipio = ${ID_MUNICIPIO};")"
echo "dim_municipio após 1a carga: ${V1}"

echo
echo "[2] Alteração territorial: IBGE renomeia o município; reaplica SCD2"
Q "UPDATE municipio SET nome_municipio = 'Vila Nova' WHERE id_municipio = ${ID_MUNICIPIO};" >/dev/null
Q "SELECT aplicar_scd2_municipio(DATE '2024-06-15');" >/dev/null

TODAS="$(Q "SELECT nome_municipio || '|' || valid_from || '|' || COALESCE(valid_to::text,'NULL') || '|' || is_current FROM dim_municipio WHERE id_municipio = ${ID_MUNICIPIO} ORDER BY valid_from;")"
echo "dim_municipio após renomeação (todas as versões, histórico preservado):"
echo "$TODAS"

QTD="$(Q "SELECT count(*) FROM dim_municipio WHERE id_municipio = ${ID_MUNICIPIO};")"
SK_DISTINTAS="$(Q "SELECT count(DISTINCT sk_municipio) FROM dim_municipio WHERE id_municipio = ${ID_MUNICIPIO};")"

ESPERADO_TODAS="Vila Antiga|1900-01-01|2024-06-15|false
Vila Nova|2024-06-15|NULL|true"

echo
if [ "$TODAS" = "$ESPERADO_TODAS" ] && [ "$QTD" = "2" ] && [ "$SK_DISTINTAS" = "2" ]; then
  echo "=== RESULTADO: versão antiga preservada (is_current=f, valid_to fechado); nova versão corrente com sk_municipio distinta ✓ ==="
else
  echo "=== RESULTADO: divergência ==="
  echo "esperado:"
  echo "$ESPERADO_TODAS"
  exit 1
fi

echo
echo "[3] Duas alterações no mesmo município no mesmo dia (mesma valid_from): não deve colidir"
Q "UPDATE municipio SET nome_municipio = 'Vila Temporaria' WHERE id_municipio = ${ID_MUNICIPIO};" >/dev/null
Q "SELECT aplicar_scd2_municipio(DATE '2024-06-20');" >/dev/null
Q "UPDATE municipio SET nome_municipio = 'Vila Nova' WHERE id_municipio = ${ID_MUNICIPIO};" >/dev/null
Q "SELECT aplicar_scd2_municipio(DATE '2024-06-20');" >/dev/null

TODAS2="$(Q "SELECT nome_municipio || '|' || valid_from || '|' || COALESCE(valid_to::text,'NULL') || '|' || is_current FROM dim_municipio WHERE id_municipio = ${ID_MUNICIPIO} ORDER BY valid_from;")"
echo "dim_municipio após 2 mudanças no mesmo dia (colapsa para o estado final do dia):"
echo "$TODAS2"

ESPERADO_TODAS2="Vila Antiga|1900-01-01|2024-06-15|false
Vila Nova|2024-06-15|2024-06-20|false
Vila Nova|2024-06-20|NULL|true"

echo
if [ "$TODAS2" = "$ESPERADO_TODAS2" ]; then
  echo "=== RESULTADO: duas mudanças no mesmo dia não colidem na surrogate key; estado final correto ✓ ==="
else
  echo "=== RESULTADO: divergência ==="
  echo "esperado:"
  echo "$ESPERADO_TODAS2"
  exit 1
fi
