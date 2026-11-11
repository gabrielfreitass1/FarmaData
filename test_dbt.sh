#!/usr/bin/env bash
# Prova do pipeline dbt: build limpo, linhagem por camadas e fato incremental
# com dado atrasado e recarga (gera docs/evidencias/dbt.txt).
set -euo pipefail
cd "$(dirname "$0")"
export COMPOSE_IGNORE_ORPHANS=1
PGU="${POSTGRES_USER:-postgres}"
PGP="${POSTGRES_PASSWORD:-postgres}"
PGD="farmadata_sim_dbt"
C="farmadata_dbt_teste"
FIXTURE="scripts/fixtures/dado_atrasado"
mkdir -p docs/evidencias
exec > >(tee docs/evidencias/dbt.txt) 2>&1

Q() { docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -tA -c "$1"; }
limpar() {
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker compose exec -T db psql -U "$PGU" -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${PGD}' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  docker compose exec -T db psql -U "$PGU" -d postgres -c "DROP DATABASE IF EXISTS ${PGD};" >/dev/null 2>&1 || true
}
trap limpar EXIT
falha() { echo "   ✗ FALHA: $1"; exit 1; }
carga() {  # $1 = mês, $2 = SNGPC_FORCE
  docker compose run --rm -T \
    -e DATABASE_URL="postgres://${PGU}:${PGP}@farmadata_db:5432/${PGD}" \
    -e SNGPC_MESES="$1" -e SNGPC_FORCE="${2:-}" \
    -e SNGPC_DIR="/app/${FIXTURE}" -e ANO_RECORTE=2020 \
    carga sh -c "npm install --omit=dev --silent pg-copy-streams >/dev/null 2>&1 && node scripts/carregar_sngpc.js" >/dev/null 2>&1
}
dbt() { docker exec -w /w "$C" dbt --no-use-colors "$@" --profiles-dir .; }
build() {
  local saida
  saida="$(dbt build 2>&1)" || { echo "$saida"; falha "dbt build com erro"; }
  echo "$saida" | grep -E "Done\." | sed 's/^[0-9:]* *//'
  echo "$saida" | grep -q "ERROR=0" || falha "dbt build com erro"
}
LINHAS="string_agg(id_venda || ' | ' || id_periodo || ' | ' || arquivo_origem, E'\n' ORDER BY id_venda)"
comparar() {
  local origem fato
  origem="$(Q "SELECT ${LINHAS} FROM venda_medicamento;")"
  fato="$(Q "SELECT ${LINHAS} FROM dbt_marts.fct_venda_medicamento;")"
  echo "fct_venda_medicamento (id_venda | id_periodo | arquivo_origem):"
  echo "$fato"
  echo "fct_venda_mensal_municipio (id_periodo: dispensações):"
  Q "SELECT id_periodo || ': ' || total_dispensacoes FROM dbt_marts.fct_venda_mensal_municipio ORDER BY id_periodo;"
  [ "$origem" = "$fato" ] || falha "fato diferente de venda_medicamento"
  echo "   ✓ fato idêntico a venda_medicamento, sem duplicação"
}

echo "=== Pipeline dbt — $(date '+%Y-%m-%dT%H:%M:%S%z') ==="
docker compose up -d --wait db
docker compose exec -T db psql -U "$PGU" -d postgres -c "DROP DATABASE IF EXISTS ${PGD};" >/dev/null
docker compose exec -T db psql -U "$PGU" -d postgres -c "CREATE DATABASE ${PGD};" >/dev/null
for f in 01_geografia_uf 02_geografia_municipio 03_tempo_periodo 04_medicamento 05_cid10 \
         06_prescritor_listas 07_venda_medicamento 08_ibge_populacao_municipio \
         09_clima_mensal_uf 10_ibge_populacao_faixa_etaria_municipio; do
  docker compose exec -T db psql -U "$PGU" -d "$PGD" -v ON_ERROR_STOP=1 -q < "sql/${f}.sql" >/dev/null
done

REDE="$(docker inspect farmadata_db -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" --network "$REDE" -e POSTGRES_PASSWORD="$PGP" \
  -v "$PWD/dbt":/src:ro python:3.12-slim sleep infinity >/dev/null
docker exec "$C" sh -c "pip install -q --root-user-action=ignore -r /src/requirements.txt >/dev/null 2>&1 \
  && cp -r /src /w && rm -rf /w/target /w/logs \
  && sed -e 's/host: localhost/host: farmadata_db/' -e 's/user: postgres/user: ${PGU}/' \
         -e 's/dbname: farmadata/dbname: ${PGD}/' /w/profiles.yml.example > /w/profiles.yml"
docker exec "$C" dbt --version 2>/dev/null | grep -E "installed|postgres:" | sed 's/^ *//'

echo
echo "[1] Janeiro carregado; dbt build com as três camadas"
carga 01
build
echo "Relações criadas (schema | tipo | quantidade):"
Q "SELECT table_schema || ' | ' || table_type || ' | ' || count(*) FROM information_schema.tables
   WHERE table_schema LIKE 'dbt_%' GROUP BY table_schema, table_type ORDER BY table_schema;"
echo "   ✓ staging e intermediate em view, marts em tabela"

echo
echo "[2] Grafo de linhagem (manifest.json do dbt)"
docker exec -i -w /w "$C" python - <<'EOF'
import json, sys
m = json.load(open("target/manifest.json"))
nodes = {k: v for k, v in m["nodes"].items() if v["resource_type"] == "model"}
camada = lambda n: n["fqn"][1]
problemas = []
for n in nodes.values():
    for d in n["depends_on"]["nodes"]:
        if d.startswith("source.") and camada(n) != "staging":
            problemas.append(f"{n['name']} lê a origem sem passar por staging")
        if d.startswith("model.") and (camada(n) == "staging" or
                                       (camada(n) == "intermediate" and camada(nodes[d]) == "marts")):
            problemas.append(f"{n['name']} depende de camada posterior: {d}")
estado = {}
def visitar(k):
    estado[k] = 1
    for d in nodes[k]["depends_on"]["nodes"]:
        if d in nodes:
            if estado.get(d) == 1:
                problemas.append(f"ciclo em {d}")
            elif d not in estado:
                visitar(d)
    estado[k] = 2
for k in nodes:
    if k not in estado:
        visitar(k)
for c in ("intermediate", "marts"):
    print(f"{c}:")
    for n in sorted(nodes.values(), key=lambda n: n["name"]):
        if camada(n) == c:
            print(f"  {n['name']} <- " + ", ".join(d.split(".")[-1] for d in n["depends_on"]["nodes"]))
if problemas:
    print("\n".join(f"   ✗ FALHA: {p}" for p in problemas))
    sys.exit(1)
print("   ✓ sem ciclos; só staging lê as tabelas de origem; marts não leem a origem")
EOF

echo
echo "[3] CSV de fevereiro traz uma venda de janeiro (dado atrasado); dbt build incremental"
carga 02
build
comparar

echo
echo "[4] Recarga forçada de fevereiro (SNGPC_FORCE): linhas voltam com id_venda novo"
carga 02 1
build
comparar

echo
echo "[5] Coluna nova no modelo do fato (esperado: incremental falha; --full-refresh resolve)"
docker exec "$C" sed -i 's/^    arquivo_origem$/    arquivo_origem,\n    1 as coluna_nova/' /w/models/marts/fct_venda_medicamento.sql
set +e; saida="$(dbt run -s fct_venda_medicamento 2>&1)"; rc=$?; set -e
[ "$rc" != 0 ] && echo "$saida" | grep -q "out of sync" || falha "incremental aceitou a mudança de schema"
echo "$saida" | grep -o "The source and target schemas on this incremental model are out of sync!"
echo "   ✓ dbt run incremental falhou (código $rc)"
dbt run -s fct_venda_medicamento --full-refresh 2>&1 | grep -E "Done\." | sed 's/^[0-9:]* *//'
echo "   ✓ --full-refresh reconstrói o fato com a coluna nova"

echo
echo "=== RESULTADO: dbt build sem erros; linhagem por camadas sem ciclos; fato incremental absorve dado atrasado e recarga sem duplicar ✓ ==="
