"""DAG FarmaData: extração SNGPC -> modelo dimensional -> validação de qualidade.

Uma execução (DAG run) = um mês de referência do SNGPC, dado pelo
``data_interval_start`` do Airflow. Agendamento mensal; o histórico é
reprocessado por backfill (``airflow dags backfill``), nunca por catchup
automático. Ver docs/orchestration/README.md.

Grafo (linear, sem ramos paralelos):

    verificar_fonte_sngpc >> extrair_sngpc >> transformar_modelo_dimensional >> validar_qualidade

Por que linear e serializado (max_active_runs=1):
  - extrair_sngpc usa advisory lock no PostgreSQL (uma carga SNGPC por vez);
    duas execuções mensais em paralelo só ficariam esperando o lock.
  - transformar_modelo_dimensional recarrega a fato inteira (TRUNCATE + INSERT)
    e aplica o SCD2 global; rodar dois meses ao mesmo tempo faria um TRUNCATE
    apagar o trabalho do outro.

Variáveis de ambiente (lidas pelos workers):
  FARMADATA_DIR           raiz do repositório (scripts/ e sql/)      [padrão: /opt/farmadata]
  FARMADATA_DATABASE_URL  conexão do banco analítico                 [obrigatória]
  FARMADATA_SNGPC_DIR     diretório com os CSVs; vazio = baixa da Anvisa
  FARMADATA_NODE          executável do Node.js                      [padrão: node]

Injeção de falha (teste do retry): Airflow Variable ``farmadata_falha_injetada``
com JSON ``{"task_id": "verificar_fonte_sngpc", "falhas": 2}`` faz a task falhar
nas 2 primeiras tentativas e passar na 3ª (``"mes": "202003"`` restringe a um mês).
Apagar a Variable desliga a injeção.
"""
from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pendulum
from airflow import DAG
from airflow.exceptions import AirflowException
from airflow.models import Variable
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

log = logging.getLogger(__name__)

FARMADATA_DIR = os.environ.get("FARMADATA_DIR", "/opt/farmadata")
ANVISA_URL = "https://dados.anvisa.gov.br/dados/SNGPC/Industrializados"
ARQUIVO_ALERTAS = Path(os.environ.get("AIRFLOW_HOME", "/tmp")) / "alertas_farmadata.jsonl"
VARIAVEL_FALHA = "farmadata_falha_injetada"


# ---------------------------------------------------------------------------
# Alertas
# ---------------------------------------------------------------------------
def _alertar(nivel: str, context: dict) -> None:
    """Registra um alerta estruturado: no log da task e num arquivo JSONL.

    Em produção este é o ponto de integração com e-mail/Slack/PagerDuty;
    aqui o destino é um arquivo para que o disparo seja auditável.
    """
    ti = context["task_instance"]
    alerta = {
        "nivel": nivel,
        "emitido_em": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "dag_id": ti.dag_id,
        "task_id": ti.task_id,
        "run_id": ti.run_id,
        "mes_referencia": context["data_interval_start"].strftime("%Y%m"),
        "tentativa": ti.try_number,
        "max_tentativas": ti.max_tries + 1,
        "proxima_tentativa_em": (
            ti.next_retry_datetime().isoformat(timespec="seconds") if nivel == "RETRY" else None
        ),
        "erro": str(context.get("exception")),
    }
    log.warning("[ALERTA %s] %s", nivel, json.dumps(alerta, ensure_ascii=False))
    with ARQUIVO_ALERTAS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(alerta, ensure_ascii=False) + "\n")


def alerta_retry(context: dict) -> None:
    _alertar("RETRY", context)


def alerta_falha(context: dict) -> None:
    _alertar("FALHA", context)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _db_url() -> str:
    url = os.environ.get("FARMADATA_DATABASE_URL")
    if not url:
        raise AirflowException("FARMADATA_DATABASE_URL não definida")
    return url


def _arquivo_mes(mes: str) -> str:
    return f"EDA_Industrializados_{mes}.csv"


def _falha_injetada(task_id: str, tentativa: int, mes: str) -> None:
    """Falha de propósito nas N primeiras tentativas se a Variable mandar.

    Chave opcional "mes" (AAAAMM) restringe a injeção a um único mês.
    """
    cfg = Variable.get(VARIAVEL_FALHA, default_var=None, deserialize_json=True)
    if not cfg or cfg.get("task_id") != task_id:
        return
    if cfg.get("mes") and str(cfg["mes"]) != mes:
        return
    falhas = int(cfg.get("falhas", 0))
    if tentativa <= falhas:
        raise AirflowException(
            f"[FALHA INJETADA] fonte SNGPC indisponível (simulação de HTTP 503) — "
            f"tentativa {tentativa}/{falhas} programada para falhar"
        )
    log.info("[FALHA INJETADA] tentativa %s > %s falhas programadas: seguindo normalmente", tentativa, falhas)


# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------
def verificar_fonte_sngpc(data_interval_start, ti, **_) -> str:
    """Upstream de tudo: confirma que o CSV do mês existe antes de carregar."""
    mes = data_interval_start.strftime("%Y%m")
    _falha_injetada(ti.task_id, ti.try_number, mes)

    arquivo = _arquivo_mes(mes)
    dir_local = os.environ.get("FARMADATA_SNGPC_DIR")
    if dir_local:
        caminho = Path(dir_local) / arquivo
        if not caminho.is_file():
            raise AirflowException(f"CSV do mês {mes} ausente em {dir_local}")
        log.info("Fonte local OK: %s (%d bytes)", caminho, caminho.stat().st_size)
        return str(caminho)

    url = f"{ANVISA_URL}/{arquivo}"
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            log.info("Fonte Anvisa OK: %s (HTTP %s, %s bytes)", url, r.status, r.headers.get("Content-Length"))
    except urllib.error.URLError as e:
        raise AirflowException(f"Fonte SNGPC indisponível para {mes}: {e}") from e
    return url


def transformar_modelo_dimensional(**_) -> int:
    """SCD2 de município e recarga da fato (funções de sql/11 e sql/12)."""
    import psycopg

    with psycopg.connect(_db_url()) as conn:
        novos, versionados = conn.execute("SELECT * FROM aplicar_scd2_municipio()").fetchone()
        linhas = conn.execute("SELECT carregar_fato_venda_medicamento()").fetchone()[0]
    log.info("dim_municipio: +%s novos, %s versionados | fato_venda_medicamento: %s linhas",
             novos, versionados, linhas)
    return linhas


def validar_qualidade(data_interval_start, **_) -> dict:
    """Regras de qualidade do mês de referência. Qualquer violação falha a task."""
    import psycopg

    mes = data_interval_start.strftime("%Y%m")
    arquivo = _arquivo_mes(mes)
    with psycopg.connect(_db_url()) as conn:
        def um(sql, *p):
            return conn.execute(sql, p).fetchone()[0]

        m = {
            "carga_registrada": um("SELECT count(*) FROM carga_arquivo WHERE arquivo = %s", arquivo),
            "vendas_do_arquivo": um("SELECT count(*) FROM venda_medicamento WHERE arquivo_origem = %s", arquivo),
            "vendas_no_periodo": um("SELECT count(*) FROM venda_medicamento WHERE id_periodo = %s", int(mes)),
            "fato_no_periodo": um("SELECT count(*) FROM fato_venda_medicamento WHERE id_periodo = %s", int(mes)),
            "fato_total": um("SELECT count(*) FROM fato_venda_medicamento"),
            "venda_total": um("SELECT count(*) FROM venda_medicamento"),
            "fato_sem_municipio_valido": um("""
                SELECT count(*) FROM fato_venda_medicamento f
                LEFT JOIN dim_municipio d ON d.sk_municipio = f.sk_municipio
                WHERE f.id_periodo = %s AND (d.sk_municipio IS NULL
                   OR f.data_venda < d.valid_from OR f.data_venda >= COALESCE(d.valid_to, 'infinity'))""", int(mes)),
            "fato_quantidade_invalida": um(
                "SELECT count(*) FROM fato_venda_medicamento WHERE id_periodo = %s AND quantidade_vendida <= 0", int(mes)),
            "municipios_com_2_versoes_correntes": um("""
                SELECT count(*) FROM (SELECT id_municipio FROM dim_municipio WHERE is_current
                                      GROUP BY 1 HAVING count(*) > 1) x"""),
        }

    regras = {
        "arquivo do mês registrado em carga_arquivo": m["carga_registrada"] == 1,
        "arquivo do mês trouxe vendas": m["vendas_do_arquivo"] > 0,
        "fato do mês = vendas do mês (sem perda no join SCD2)": m["fato_no_periodo"] == m["vendas_no_periodo"],
        "fato total = venda_medicamento total": m["fato_total"] == m["venda_total"],
        "toda venda na versão SCD2 vigente na data_venda": m["fato_sem_municipio_valido"] == 0,
        "quantidade_vendida > 0": m["fato_quantidade_invalida"] == 0,
        "no máximo 1 versão corrente por município": m["municipios_com_2_versoes_correntes"] == 0,
    }
    log.info("Métricas %s: %s", mes, json.dumps(m))
    for nome, ok in regras.items():
        log.info("  [%s] %s", "OK" if ok else "FALHOU", nome)
    falhas = [n for n, ok in regras.items() if not ok]
    if falhas:
        raise AirflowException(f"Qualidade reprovada em {mes}: {falhas}")
    return m


# ---------------------------------------------------------------------------
# DAG
# ---------------------------------------------------------------------------
default_args = {
    "owner": "farmadata",
    "retries": 3,                               # >= 2 exigido; 4 tentativas no total
    "retry_delay": timedelta(seconds=20),       # base do backoff
    "retry_exponential_backoff": True,          # 20s, 40s, 80s... (com jitter do Airflow)
    "max_retry_delay": timedelta(minutes=10),   # teto do backoff
    "on_retry_callback": alerta_retry,
    "on_failure_callback": alerta_falha,
    "execution_timeout": timedelta(hours=2),
}

with DAG(
    dag_id="farmadata_pipeline",
    description="SNGPC mensal: extração -> modelo dimensional (SCD2 + fato) -> validação de qualidade",
    schedule="@monthly",
    start_date=pendulum.datetime(2020, 1, 1, tz="UTC"),
    end_date=pendulum.datetime(2020, 12, 31, tz="UTC"),  # ANO_RECORTE; meses fora dele são rejeitados pela carga
    catchup=False,           # histórico só via backfill explícito
    max_active_runs=1,       # meses em série: carga com lock + fato com TRUNCATE
    default_args=default_args,
    tags=["farmadata", "sngpc", "e3"],
    doc_md=__doc__,
) as dag:
    t_fonte = PythonOperator(
        task_id="verificar_fonte_sngpc",
        python_callable=verificar_fonte_sngpc,
    )

    # SNGPC_FORCE=1: a execução do mês sempre reprocessa o arquivo (é o que
    # torna o backfill um reprocessamento real). A carga é idempotente por
    # arquivo (DELETE + COPY na mesma transação), então reexecutar não duplica.
    t_extrair = BashOperator(
        task_id="extrair_sngpc",
        bash_command=(
            'test -n "$FARMADATA_DATABASE_URL" || { echo "FARMADATA_DATABASE_URL não definida"; exit 1; }; '
            'cd "$FARMADATA_DIR" && '
            'DATABASE_URL="$FARMADATA_DATABASE_URL" SNGPC_DIR="${FARMADATA_SNGPC_DIR:-tmp}" '
            '"${FARMADATA_NODE:-node}" scripts/carregar_sngpc.js'
        ),
        env={
            "FARMADATA_DIR": FARMADATA_DIR,
            "SNGPC_MESES": "{{ data_interval_start.strftime('%Y%m') }}",
            "SNGPC_FORCE": "1",
            "ANO_RECORTE": "{{ data_interval_start.strftime('%Y') }}",
        },
        append_env=True,
    )

    t_transformar = PythonOperator(
        task_id="transformar_modelo_dimensional",
        python_callable=transformar_modelo_dimensional,
    )

    t_validar = PythonOperator(
        task_id="validar_qualidade",
        python_callable=validar_qualidade,
    )

    t_fonte >> t_extrair >> t_transformar >> t_validar
