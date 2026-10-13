#!/usr/bin/env bash
# Prova de idempotência da ingestão em lote SNGPC (E2).
# Uso: ./test_idempotencia.sh [AAAAMM]      (padrão: 202001)
# Pré-requisitos: stack no ar (docker compose up -d db), carga inicial CONCLUÍDA
# e o mês escolhido já presente em carga_arquivo. Não rode junto com a carga inicial.
set -euo pipefail
cd "$(dirname "$0")"

ANO_MES="${1:-202001}"
ARQ="EDA_Industrializados_${ANO_MES}.csv"
MES="${ANO_MES: -2}"
PGU="${POSTGRES_USER:-postgres}"; PGD="${POSTGRES_DB:-farmadata}"

mkdir -p docs/evidencias
exec > >(tee docs/evidencias/idempotencia.txt) 2>&1

Q() { docker compose exec -T db psql -U "$PGU" -d "$PGD" -tA -c "$1"; }
CONTAINER="farmadata-teste-carga"
limpar() {
  # Ctrl+C no terminal NÃO para o container da carga; sem isso ele segue recarregando em segundo plano.
  # Parar no meio é seguro: DELETE+COPY estão numa transação (ROLLBACK preserva as linhas antigas).
  if docker ps -q --filter "name=^${CONTAINER}$" | grep -q .; then
    echo; echo "[!] Interrompido: parando o container da carga..."
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    echo "[!] Se o registro de ${ARQ} sumiu de carga_arquivo, restaure com: make carga-incremental"
  fi
}
trap limpar EXIT INT TERM
carga() {  # $1 = SNGPC_FORCE (0/1)
  docker compose run --rm -T --name "$CONTAINER" -e SNGPC_MESES="$MES" -e SNGPC_FORCE="$1" carga \
    sh -c "npm install --omit=dev --silent pg-copy-streams >/dev/null 2>&1 && node scripts/carregar_sngpc.js" \
    | grep -E "SKIP|↻|inseridas|\[!\]|ERRO|Total no banco" || true
}
snap() {  # total | linhas do arquivo | soma quantidade do arquivo
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
  echo "Há uma carga em andamento (container farmadata-carga-run-*). Espere terminar: docker ps"; exit 2
fi
PRE="$(Q "SELECT count(*) FROM carga_arquivo WHERE arquivo='${ARQ}';")" \
  || { echo "Falha ao consultar o banco (container db no ar? docker compose ps)."; exit 2; }
[ "$PRE" = "1" ] || { echo "Pré-condição: ${ARQ} não está em carga_arquivo (restaure com: make carga-incremental)."; exit 2; }

BASE="$(snap)"
echo "[0] Estado inicial  (total | arquivo: linhas|soma_qtd)"
echo "   estado: $BASE"

echo "[1] Reexecução simples (esperado: SKIP, nada muda)"
carga 0; confere

echo "[2] Tabela de controle perdida: apago o registro e reexecuto (esperado: recarrega SEM duplicar)"
Q "DELETE FROM carga_arquivo WHERE arquivo='${ARQ}';" >/dev/null
carga 0; confere

echo "[3] Recarga forçada com SNGPC_FORCE=1 (esperado: recarrega SEM duplicar)"
carga 1; confere

echo "=== RESULTADO: carga idempotente e reexecutável ✓ ==="