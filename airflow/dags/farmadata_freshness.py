"""DAG FarmaData: freshness diário da tabela de consumo (issue #29).

Separada da farmadata_pipeline (@monthly) de propósito: o atraso só existe
horas ou dias depois de uma carga. Uma checagem logo após a transformação
sempre daria OK; uma checagem diária pega a carga que entrou e a fato que não
foi reconstruída (transformação falhou, DAG pausada, recarga manual esquecida).

Regra em checar_freshness() (sql/13_controle_build.sql), a mesma usada por
scripts/checar_freshness.sh. SLA em docs/CAMADA_ANALITICA.md.

    OK   -> log; task passa
    WARN -> alerta em alertas_farmadata.jsonl; task passa
    ERRO -> task falha sem retry (AirflowFailException) e alerta; nada a jusante roda

Bloqueio a jusante: a atualização do painel entra como task depois de
checar_freshness_fato (checar_freshness_fato >> atualizar_painel), então um
ERRO impede o painel de publicar dado defasado.

Variáveis de ambiente: FARMADATA_DATABASE_URL (obrigatória),
FRESHNESS_TABELA [fato_venda_medicamento], FRESHNESS_WARN_H [24], FRESHNESS_ERRO_H [48].
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pendulum
from airflow import DAG
from airflow.exceptions import AirflowException, AirflowFailException
from airflow.operators.python import PythonOperator

log = logging.getLogger(__name__)

TABELA = os.environ.get("FRESHNESS_TABELA", "fato_venda_medicamento")
WARN_H = int(os.environ.get("FRESHNESS_WARN_H", "24"))
ERRO_H = int(os.environ.get("FRESHNESS_ERRO_H", "48"))
ARQUIVO_ALERTAS = Path(os.environ.get("AIRFLOW_HOME", "/tmp")) / "alertas_farmadata.jsonl"


def _alertar(nivel: str, ti, detalhe: dict) -> None:
    """Mesmo formato/destino dos alertas da farmadata_pipeline (arquivo JSONL auditável)."""
    alerta = {
        "nivel": nivel,
        "emitido_em": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "dag_id": ti.dag_id,
        "task_id": ti.task_id,
        "run_id": ti.run_id,
        "tentativa": ti.try_number,
        **detalhe,
    }
    log.warning("[ALERTA %s] %s", nivel, json.dumps(alerta, ensure_ascii=False))
    with ARQUIVO_ALERTAS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(alerta, ensure_ascii=False) + "\n")


def alerta_falha(context: dict) -> None:
    _alertar("FALHA", context["task_instance"], {"erro": str(context.get("exception"))})


def checar_freshness_fato(ti, **_) -> dict:
    import psycopg

    url = os.environ.get("FARMADATA_DATABASE_URL")
    if not url:
        raise AirflowException("FARMADATA_DATABASE_URL não definida")

    with psycopg.connect(url) as conn:
        status, carga, build = conn.execute(
            "SELECT status, ultima_carga, ultimo_build FROM checar_freshness(%s, %s, %s)",
            (TABELA, WARN_H, ERRO_H),
        ).fetchone()

    r = {
        "tabela": TABELA,
        "status": status,
        "ultima_carga": carga.isoformat() if carga else None,
        "ultimo_build": build.isoformat() if build else None,
        "limites_h": {"warn": WARN_H, "erro": ERRO_H},
    }
    log.info("Freshness %s: %s", TABELA, json.dumps(r))

    if status == "WARN":
        _alertar("FRESHNESS_WARN", ti, r)
    elif status != "OK":
        # Sem retry: reexecutar a checagem não reconstrói a tabela.
        raise AirflowFailException(
            f"Freshness ERRO em {TABELA}: última carga {r['ultima_carga']}, "
            f"última construção {r['ultimo_build'] or 'nunca'} (limite {ERRO_H}h)"
        )
    return r


with DAG(
    dag_id="farmadata_freshness",
    description="Freshness diário da fato_venda_medicamento frente à última carga (SLA #29)",
    schedule="@daily",
    start_date=pendulum.datetime(2026, 11, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    default_args={
        "owner": "farmadata",
        "retries": 1,                         # só para falha transitória de conexão
        "retry_delay": timedelta(minutes=1),
        "on_failure_callback": alerta_falha,
        "execution_timeout": timedelta(minutes=5),
    },
    tags=["farmadata", "freshness", "e3"],
    doc_md=__doc__,
) as dag:
    PythonOperator(
        task_id="checar_freshness_fato",
        python_callable=checar_freshness_fato,
    )
