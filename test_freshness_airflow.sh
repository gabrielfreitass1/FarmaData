#!/usr/bin/env bash
# Prova a DAG farmadata_freshness no Airflow: OK -> WARN -> ERRO -> OK, com alertas e com
# atualizar_painel bloqueada (upstream_failed) no ERRO
# (gera docs/evidencias/freshness_airflow.txt).
#
# Pré-requisito: Airflow da demo de pé e com o backfill feito (make airflow-demo e
# make airflow-backfill), apontando para o banco de testes farmadata_orquestracao.
# Não toca no banco farmadata: altera só horários de carga/build no banco da demo.
set -euo pipefail
cd "$(dirname "$0")"
export COMPOSE_IGNORE_ORPHANS=1
export MSYS_NO_PATHCONV=1   # Git Bash no Windows: não reescrever caminhos do container

PGU="${POSTGRES_USER:-postgres}"
PGD="farmadata_orquestracao"
AF="farmadata_airflow"
DAG="farmadata_freshness"
mkdir -p docs/evidencias
exec > >(tee docs/evidencias/freshness_airflow.txt) 2>&1

Q() { docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -tA -c "$1"; }

# Estado final de uma task num run (lido do metadb do Airflow; última linha ignora warnings).
estado() { docker exec "$AF" airflow tasks state "$DAG" "$1" "$2" 2>/dev/null | tail -1; }

# Roda a DAG uma vez (sem esperar o agendamento), mostra só as linhas relevantes do log
# e confere o estado das duas tasks: a checagem e o painel a jusante.
rodar() {  # $1 = data lógica distinta por cenário, $2 = estado esperado de checar_freshness_fato,
           # $3 = estado esperado de atualizar_painel
  local log rc ok=1 t esperado obtido
  set +e
  log="$(docker exec "$AF" airflow dags test "$DAG" "$1" 2>&1)"; rc=$?
  set -e
  grep -E "Freshness fato_venda_medicamento:|\[ALERTA|AirflowFailException|Marking task as" <<< "$log" \
    | grep -v 'AirflowFailException($' \
    | sed -E 's/^.*(Freshness fato_venda|\[ALERTA|AirflowFailException:|Marking task as)/   \1/' \
    | awk '!visto[$0]++'
  for t in "checar_freshness_fato:$2" "atualizar_painel:$3"; do
    esperado="${t#*:}"; obtido="$(estado "${t%%:*}" "$1")"
    if [ "$obtido" = "$esperado" ]; then
      echo "   ✓ ${t%%:*} = $obtido, como esperado"
    else
      echo "   ✗ FALHA: ${t%%:*} = ${obtido:-?}, esperava $esperado"; ok=0
    fi
  done
  echo "   (exit do dags test: $rc)"
  [ "$ok" = 1 ] || exit 1
}

echo "=== DAG ${DAG} no Airflow — $(date -Is) ==="
url="$(docker exec "$AF" printenv FARMADATA_DATABASE_URL)"
[[ "$url" == */"$PGD" ]] || { echo "Airflow aponta para ${url##*/}, não para ${PGD}. Rode make airflow-demo."; exit 1; }
echo "Airflow $(docker exec "$AF" airflow version) | banco: ${PGD}"
[ "$(Q "SELECT count(*) FROM carga_arquivo")" -gt 0 ] || { echo "Sem cargas no banco da demo. Rode make airflow-backfill."; exit 1; }

# client_min_messages=warning: esconde os NOTICE "already exists, skipping" do IF NOT EXISTS
for f in 13_controle_build 12_dimensional_fato_venda; do
  docker compose exec -T -e PGOPTIONS='-c client_min_messages=warning' db \
    psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -q < "sql/${f}.sql"
done
inicio="$(Q "SELECT now()")"

echo
echo "[1] Fato reconstruída depois da última carga (esperado: OK, checagem e painel success)"
Q "SELECT carregar_fato_venda_medicamento();" >/dev/null
rodar "2026-11-01" success success

echo
echo "[2] Carga há 30h, fato construída há 40h (esperado: WARN com alerta, checagem e painel success)"
Q "UPDATE carga_arquivo SET carregado_em = now() - interval '30 hours';
   DELETE FROM controle_build WHERE tabela = 'fato_venda_medicamento';
   INSERT INTO controle_build (tabela, construido_em) VALUES ('fato_venda_medicamento', now() - interval '40 hours');" >/dev/null
rodar "2026-11-02" success success

echo
echo "[3] Mesma carga pendente há 50h (esperado: ERRO, checagem failed sem retry, alerta FALHA, painel upstream_failed)"
Q "UPDATE carga_arquivo SET carregado_em = now() - interval '50 hours';
   DELETE FROM controle_build WHERE tabela = 'fato_venda_medicamento';
   INSERT INTO controle_build (tabela, construido_em) VALUES ('fato_venda_medicamento', now() - interval '60 hours');" >/dev/null
rodar "2026-11-03" failed upstream_failed

echo
echo "[4] Mitigação: fato reconstruída (esperado: OK, checagem e painel success)"
Q "SELECT carregar_fato_venda_medicamento();" >/dev/null
rodar "2026-11-04" success success

echo
echo "--- alertas gravados pela DAG em \$AIRFLOW_HOME/alertas_farmadata.jsonl (desde o início do teste) ---"
docker exec "$AF" python -c "
import json, os, sys
dag, inicio = sys.argv[1], sys.argv[2][:19].replace(' ', 'T')
caminho = os.path.join(os.environ.get('AIRFLOW_HOME', '/tmp'), 'alertas_farmadata.jsonl')
for linha in open(caminho, encoding='utf-8'):
    a = json.loads(linha)
    if a.get('dag_id') == dag and a['emitido_em'][:19] >= inicio:
        print(json.dumps(a, ensure_ascii=False))
" "$DAG" "$inicio"

echo
echo "=== RESULTADO: a DAG agenda a checagem, alerta no WARN, falha no ERRO e bloqueia o painel; reconstruir volta a OK ✓ ==="
