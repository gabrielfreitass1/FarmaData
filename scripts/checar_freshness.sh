#!/usr/bin/env bash
# Freshness: existe carga mais nova que a última construção da tabela de consumo?
# Regra em checar_freshness() (sql/13_controle_build.sql).
# Saída: 0 = OK, 1 = WARN, 2 = ERRO.   Uso: scripts/checar_freshness.sh <tabela>
set -euo pipefail
cd "$(dirname "$0")/.."
PGU="${POSTGRES_USER:-postgres}"
PGD="${FRESHNESS_DB:-${POSTGRES_DB:-farmadata}}"
TABELA="${1:-${FRESHNESS_TABELA:-fato_venda_medicamento}}"
WARN_H="${FRESHNESS_WARN_H:-24}"
ERRO_H="${FRESHNESS_ERRO_H:-48}"

for n in "$WARN_H" "$ERRO_H"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "[ERRO] limite de horas inválido: $n"; exit 2; }
done

SAIDA="$(docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -tA -F '|' \
  -v tabela="$TABELA" -v warn_h="$WARN_H" -v erro_h="$ERRO_H" <<'SQL'
SELECT status, coalesce(ultima_carga::text, '-'), coalesce(ultimo_build::text, 'nunca construída')
FROM checar_freshness(:'tabela', :warn_h, :erro_h);
SQL
)" || { echo "[ERRO] falha ao consultar o banco (docker compose ps)"; exit 2; }

IFS='|' read -r STATUS CARGA BUILD <<< "$SAIDA"
echo "[$STATUS] ${TABELA} | última carga: ${CARGA} | última construção: ${BUILD} | limites: warn ${WARN_H}h, erro ${ERRO_H}h"
case "$STATUS" in OK) exit 0;; WARN) exit 1;; *) exit 2;; esac
