#!/usr/bin/env bash
# Prova de idempotência da ingestão em lote SNGPC (E2).
# Uso: ./test_idempotencia.sh [AAAAMM]      (padrão: 202001)
set -euo pipefail
cd "$(dirname "$0")"

ANO_MES="${1:-202001}"
ARQ="EDA_Industrializados_${ANO_MES}.csv"
MES="${ANO_MES: -2}"
PGU="${POSTGRES_USER:-postgres}"; PGD="${POSTGRES_DB:-farmadata}"

mkdir -p docs/evidencias
exec > >(tee docs/evidencias/log_idempotencia.txt) 2>&1

Q() { docker compose exec -T db psql -U "$PGU" -d "$PGD" -tA -c "$1"; }
CONTAINER="farmadata-teste-carga"

limpar() {
  if docker ps -q --filter "name=^${CONTAINER}$" | grep -q .; then
    echo; echo "[!] Interrompido: parando o container da carga..."
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    echo "[!] Se o registro de ${ARQ} sumiu de carga_arquivo, restaure com: make carga-incremental"
  fi
}
trap limpar EXIT INT TERM

carga() {  # $1 = SNGPC_FORCE (0/1)
  OUT="$(docker compose run --rm -T --name "$CONTAINER" -e SNGPC_MESES="$MES" -e SNGPC_FORCE="$1" carga \
    sh -c "npm install --omit=dev --silent pg-copy-streams >/dev/null 2>&1 && node scripts/carregar_sngpc.js" \
    | grep -E "SKIP|↻|inseridas|\[!\]|ERRO|Total no banco" || true)"
  echo "$OUT"
}

espera() {
  echo "$OUT" | grep -q "$1" || { echo "   ✗ FALHA: esperava '$1' na saída. A recarga pode ter falhado."; exit 1; }
}

snap() {
  echo "$(Q "SELECT count(*) FROM venda_medicamento;") | $(Q "SELECT count(*)||'|'||coalesce(sum(quantidade_vendida),0) FROM venda_medicamento WHERE arquivo_origem='${ARQ}';")"
}

confere() {
  local atual; atual="$(snap)"
  echo "   estado: $atual"
  if [ "$atual" != "$BASE" ]; then echo "   ✗ FALHA: difere do estado inicial ($BASE)"; exit 1; fi
  echo "   ✓ idêntico ao estado inicial"
}

echo "=== Teste de idempotência — ${ARQ} — $(date -Is) ==="
if docker ps -q --filter "name=farmadata-carga-run" | grep -q .; then
  echo "Há uma carga em andamento (container farmadata-carga-run-*). Espere terminar."; exit 2
fi
PRE="$(Q "SELECT count(*) FROM carga_arquivo WHERE arquivo='${ARQ}';")" \
  || { echo "Falha ao consultar o banco (container db no ar?)."; exit 2; }
[ "$PRE" = "1" ] || { echo "Pré-condição: ${ARQ} não está em carga_arquivo (restaure com: make carga-incremental)."; exit 2; }

BASE="$(snap)"
echo "[0] Estado inicial  (total | arquivo: linhas|soma_qtd)"
echo "   estado: $BASE"

echo "[1] Reexecução simples (esperado: SKIP, nada muda)"
OUT=$(carga 0); espera "SKIP"; confere

echo "[2] Tabela de controle perdida: apago o registro e reexecuto (esperado: recarrega SEM duplicar)"
Q "DELETE FROM carga_arquivo WHERE arquivo='${ARQ}';" >/dev/null
OUT=$(carga 0); espera "↻"; confere
[ "$(Q "SELECT count(*) FROM carga_arquivo WHERE arquivo='${ARQ}';")" = 1 ] || { echo "   ✗ controle não restaurado"; exit 1; }

echo "[3] Recarga forçada com SNGPC_FORCE=1 (esperado: recarrega SEM duplicar)"
OUT=$(carga 1); espera "↻"; confere

echo "=== RESULTADO: carga idempotente e reexecutável ✓ ==="