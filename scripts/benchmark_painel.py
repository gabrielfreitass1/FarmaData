"""Benchmark do Painel Analítico (Issue #30, ADR-005).

Mede ao vivo, 5 vezes cada, a consulta da aba de clima do painel (antimicrobianos por
mês x clima, visão "TODAS"):

  B  PostgreSQL star schema: fato_venda_medicamento + dim_municipio + clima_mensal_uf.
  C  DuckDB lendo a tabela Delta (data/lakehouse/delta/venda_medicamento) + clima_mensal_uf.
     O clima (27 UFs x 12 meses) é lido do PostgreSQL uma vez, fora da cronometragem.

A (SQL puro / CLI) não é medida à parte: roda a mesma consulta da B no mesmo banco.
Nenhum número é estimado: o que não roda aparece como "não medido" com o motivo.
Ao final, o total de embalagens de B e C é comparado para confirmar que as duas
devolvem o mesmo resultado.

Pré-requisitos: B precisa da fato construída (make modelo-dimensional);
C precisa da tabela Delta exportada (make lakehouse).

Uso:
  make benchmark-painel
  python scripts/benchmark_painel.py
"""

import os
import time

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql+psycopg2://postgres:postgres@localhost:5432/farmadata"
)
for prefixo in ("postgresql://", "postgres://"):
    if DATABASE_URL.startswith(prefixo):
        DATABASE_URL = DATABASE_URL.replace(prefixo, "postgresql+psycopg2://", 1)

LAKEHOUSE_DIR = os.environ.get("LAKEHOUSE_DIR", "data/lakehouse")
TABELA_DELTA = os.path.join(LAKEHOUSE_DIR, "delta", "venda_medicamento")
ANO_RECORTE = int(os.environ.get("ANO_RECORTE", "2020"))

REPETICOES = 5

# Mesma consulta da aba 2 do painel (src/dashboard/app.py, carregar_dados_clima), visão "TODAS".
SQL_B = """
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

# Mesma conta sobre o Delta (modelo achatado: sigla_uf, ano e mes já vêm na linha).
SQL_C = """
WITH mensal AS (
  SELECT c.sigla_uf, v.ano * 100 + v.mes AS id_periodo, c.temp_media_c, c.precipitacao_media_mm,
         SUM(v.quantidade_vendida) AS vol
  FROM delta_scan('{tabela}') v
  JOIN clima c ON c.sigla_uf = v.sigla_uf AND c.id_periodo = v.ano * 100 + v.mes
  WHERE v.eh_antimicrobiano AND v.ano = {ano}
  GROUP BY 1, 2, 3, 4
)
SELECT id_periodo, AVG(temp_media_c), AVG(precipitacao_media_mm), SUM(vol)
FROM mensal
GROUP BY id_periodo
ORDER BY id_periodo
"""


def cronometrar(executar):
    tempos, resultado = [], None
    for _ in range(REPETICOES):
        t0 = time.perf_counter()
        resultado = executar()
        tempos.append((time.perf_counter() - t0) * 1000.0)
    return sorted(tempos), resultado


def medir_b(engine):
    from sqlalchemy import text

    with engine.connect() as conn:
        linhas = conn.execute(text("SELECT count(*) FROM fato_venda_medicamento")).scalar()
        if not linhas:
            return {"motivo": "fato_venda_medicamento vazia (rode make modelo-dimensional)"}
        tempos, res = cronometrar(lambda: conn.execute(text(SQL_B)).fetchall())
    return {"linhas": linhas, "tempos": tempos, "total": sum(float(r[3]) for r in res)}


def medir_c(engine):
    if not os.path.isdir(os.path.join(TABELA_DELTA, "_delta_log")):
        return {"motivo": f"tabela Delta não encontrada em {TABELA_DELTA} (rode make lakehouse)"}
    try:
        import duckdb
    except ImportError:
        return {"motivo": "pacote duckdb não instalado"}
    from sqlalchemy import text

    with engine.connect() as conn:
        clima = conn.execute(text(
            "SELECT sigla_uf, id_periodo, temp_media_c::float8, precipitacao_media_mm::float8 "
            "FROM clima_mensal_uf"
        )).fetchall()
    con = duckdb.connect()
    con.execute("INSTALL delta; LOAD delta;")
    con.execute("CREATE TABLE clima (sigla_uf VARCHAR, id_periodo INTEGER, "
                "temp_media_c DOUBLE, precipitacao_media_mm DOUBLE)")
    con.executemany("INSERT INTO clima VALUES (?, ?, ?, ?)", [tuple(r) for r in clima])
    linhas = con.execute(
        f"SELECT count(*) FROM delta_scan('{TABELA_DELTA}') WHERE ano = {ANO_RECORTE}"
    ).fetchone()[0]
    sql = SQL_C.format(tabela=TABELA_DELTA, ano=ANO_RECORTE)
    tempos, res = cronometrar(lambda: con.execute(sql).fetchall())
    con.close()
    return {"linhas": linhas, "tempos": tempos, "total": sum(float(r[3]) for r in res)}


def fmt_int(n):
    return f"{n:,.0f}".replace(",", ".")


def linha(nome, r):
    if "tempos" in r:
        t = r["tempos"]
        return f"{nome:<42} | {t[len(t) // 2]:>10.0f} | {t[-1]:>10.0f}"
    return f"{nome:<42} | {'não medido':>10} | {'não medido':>10}"


def main():
    from sqlalchemy import create_engine

    engine = create_engine(DATABASE_URL, connect_args={"connect_timeout": 5})
    print("Benchmark do painel (ADR-005) — consulta da aba 2: antimicrobianos por mês x clima")
    print(f"Execuções por alternativa: {REPETICOES}, resultado do painel sem cache (st.cache_data)")
    print()

    resultados = {"B": medir_b(engine), "C": medir_c(engine)}
    for alt, r in resultados.items():
        if "tempos" in r:
            print(f"{alt}: {fmt_int(r['linhas'])} linhas | tempos (ms): "
                  f"{', '.join(f'{t:.0f}' for t in r['tempos'])}")
        else:
            print(f"{alt}: não medido — {r['motivo']}")
    print()

    print(f"{'Alternativa':<42} | {'p50 (ms)':>10} | {'máx (ms)':>10}")
    print("-" * 70)
    print(f"{'A (SQL puro / CLI)':<42} | {'= B':>10} | {'= B':>10}")
    print(linha("B (Streamlit + PostgreSQL star schema)", resultados["B"]))
    print(linha("C (Streamlit + DuckDB / Delta Lake)", resultados["C"]))
    print()
    print("A roda a mesma consulta da B no mesmo banco; não é medida à parte.")
    print("Com 5 execuções não há p95 confiável; o pior caso é reportado como máx.")

    b, c = resultados["B"], resultados["C"]
    if "total" in b and "total" in c:
        igual = abs(b["total"] - c["total"]) < 0.5
        print(f"Conferência: total de embalagens B = {fmt_int(b['total'])}, "
              f"C = {fmt_int(c['total'])} -> {'iguais' if igual else 'DIFERENTES'}")


if __name__ == "__main__":
    main()
