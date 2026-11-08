#!/usr/bin/env bash
# Freshness: existe carga mais nova que a última construção da tabela de consumo?
# Saída: 0 = OK, 1 = WARN, 2 = ERRO.   Uso: scripts/checar_freshness.sh <tabela>
set -euo pipefail
cd "$(dirname "$0")/.."
PGU="${POSTGRES_USER:-postgres}"
PGD="${FRESHNESS_DB:-${POSTGRES_DB:-farmadata}}"
TABELA="${1:-${FRESHNESS_TABELA:-fato_municipio_mes}}"
WARN_H="${FRESHNESS_WARN_H:-24}"
ERRO_H="${FRESHNESS_ERRO_H:-48}"

SAIDA="$(docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -tA -F '|' -c "
WITH x AS (
  SELECT (SELECT max(carregado_em) FROM carga_arquivo) AS carga,
         (SELECT max(construido_em) FROM controle_build WHERE tabela = '${TABELA}') AS build)
SELECT CASE
         WHEN build IS NULL THEN 'ERRO'
         WHEN carga IS NULL OR carga <= build THEN 'OK'
         WHEN now() - carga > interval '${ERRO_H} hours' THEN 'ERRO'
         WHEN now() - carga > interval '${WARN_H} hours' THEN 'WARN'
         ELSE 'OK' END,
       coalesce(carga::text,'-'), coalesce(build::text,'nunca construída')
FROM x;")" || { echo "[ERRO] falha ao consultar o banco (docker compose ps)"; exit 2; }

IFS='|' read -r STATUS CARGA BUILD <<< "$SAIDA"
echo "[$STATUS] ${TABELA} | última carga: ${CARGA} | última construção: ${BUILD} | limites: warn ${WARN_H}h, erro ${ERRO_H}h"
case "$STATUS" in OK) exit 0;; WARN) exit 1;; *) exit 2;; esac