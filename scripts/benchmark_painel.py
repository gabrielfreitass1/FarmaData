"""Benchmark do Painel Analítico (Issue #30, ADR-005).

Mede ao vivo a Alternativa B (PostgreSQL star schema): a consulta da aba de clima do
painel (fato_venda_medicamento + dim_municipio + clima_mensal_uf), sem cache, 5 vezes.
As alternativas A e C não são medidas por este script e aparecem como "não medido":
nenhum número é estimado ou copiado de outro lugar.

Pré-requisito: fato_venda_medicamento construída (make modelo-dimensional).

Uso:
  make benchmark-painel
  python scripts/benchmark_painel.py
"""

import os
import sys
import time

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql+psycopg2://postgres:postgres@localhost:5432/farmadata"
)
for prefixo in ("postgresql://", "postgres://"):
    if DATABASE_URL.startswith(prefixo):
        DATABASE_URL = DATABASE_URL.replace(prefixo, "postgresql+psycopg2://", 1)

REPETICOES = 5

# Mesma consulta da aba 2 do painel (src/dashboard/app.py, carregar_dados_clima), visão "TODAS".
SQL_PAINEL = """
WITH mensal AS (
  SELECT c.sigla_uf, f.id_periodo, c.temp_media_c, c.precipitacao_media_mm, SUM(f.quantidade_vendida) AS vol
  FROM fato_venda_medicamento f
  JOIN dim_municipio m ON m.sk_municipio = f.sk_municipio
  JOIN clima_mensal_uf c ON c.sigla_uf = m.sigla_uf AND c.id_periodo = f.id_periodo
  WHERE f.eh_antimicrobiano
  GROUP BY c.sigla_uf, f.id_periodo, c.temp_media_c, c.precipitacao_media_mm
)
SELECT id_periodo, AVG(temp_media_c), AVG(precipitacao_media_mm), SUM(vol)
FROM mensal
GROUP BY id_periodo
ORDER BY id_periodo
"""


def medir_postgres():
    from sqlalchemy import create_engine, text

    engine = create_engine(DATABASE_URL, connect_args={"connect_timeout": 5})
    with engine.connect() as conn:
        linhas = conn.execute(text("SELECT count(*) FROM fato_venda_medicamento")).scalar()
        if not linhas:
            sys.exit("fato_venda_medicamento vazia: rode make modelo-dimensional antes do benchmark.")
        tempos = []
        for _ in range(REPETICOES):
            t0 = time.perf_counter()
            conn.execute(text(SQL_PAINEL)).fetchall()
            tempos.append((time.perf_counter() - t0) * 1000.0)
    tempos.sort()
    return linhas, tempos


def main():
    print("Benchmark do painel (ADR-005) — consulta: fato + município + clima (aba 2)")
    linhas, tempos = medir_postgres()
    p50 = tempos[len(tempos) // 2]
    print(f"Linhas na fato: {linhas:,}".replace(",", "."))
    print(f"Execuções: {REPETICOES}, sem cache | tempos (ms): {', '.join(f'{t:.0f}' for t in tempos)}")
    print()
    print(f"{'Alternativa':<42} | {'p50 (ms)':>10} | {'máx (ms)':>10}")
    print("-" * 70)
    print(f"{'A (SQL puro / CLI)':<42} | {'não medido':>10} | {'não medido':>10}")
    print(f"{'B (Streamlit + PostgreSQL star schema)':<42} | {p50:>10.0f} | {tempos[-1]:>10.0f}")
    print(f"{'C (Streamlit + DuckDB / Delta Lake)':<42} | {'não medido':>10} | {'não medido':>10}")
    print()
    print("Com 5 execuções não há p95 confiável; o pior caso é reportado como máx.")


if __name__ == "__main__":
    main()
