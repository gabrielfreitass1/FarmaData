#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

PGU="${POSTGRES_USER:-postgres}"
PGD="${POSTGRES_DB:-farmadata}"
MIN_VENDAS="${MIN_VENDAS:-1000000}"
mkdir -p docs/evidencias
LOG="docs/evidencias/qualidade_dados.txt"
exec > >(tee "$LOG") 2>&1
echo "=== Suíte de qualidade FarmaData | $(date -Iseconds) | mínimo=${MIN_VENDAS} ==="
docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -v min_vendas="$MIN_VENDAS" -f - < tests/qualidade_dados.sql
echo "RESULTADO: APROVADO"
