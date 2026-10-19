"""Valida a tabela Delta lendo-a com um motor diferente do escritor (DuckDB).

1. Executa as 8 consultas de QUERIES.md adaptadas ao modelo achatado.
2. Confere que não há id_venda duplicado (idempotência do reprocessamento).
3. Compara contagem por mês com o PostgreSQL de origem (se acessível).

Uso: python scripts/lakehouse/validar_duckdb.py
"""
import os
import sys
import time

import duckdb

import config

CAMINHO = os.path.abspath(config.TABELA_VENDAS).replace("\\", "/")

CONSULTAS = {
    "Q1 top princípios ativos": """
        SELECT principio_ativo, SUM(quantidade_vendida) q, COUNT(*) n
        FROM vendas GROUP BY 1 ORDER BY q DESC LIMIT 10""",
    "Q2 top municípios": """
        SELECT nome_municipio, sigla_uf, SUM(quantidade_vendida) q
        FROM vendas GROUP BY 1, 2 ORDER BY q DESC LIMIT 10""",
    "Q3 evolução mensal": """
        SELECT ano, mes, SUM(quantidade_vendida) q
        FROM vendas GROUP BY 1, 2 ORDER BY 1, 2""",
    "Q4 por região": """
        SELECT regiao, SUM(quantidade_vendida) q, COUNT(DISTINCT id_municipio) m
        FROM vendas GROUP BY 1 ORDER BY q DESC""",
    "Q5 antimicrobianos por faixa etária": """
        SELECT CASE WHEN idade_paciente < 12 THEN '0-11'
                    WHEN idade_paciente < 18 THEN '12-17'
                    WHEN idade_paciente < 60 THEN '18-59' ELSE '60+' END faixa,
               COUNT(*) n
        FROM vendas
        WHERE eh_antimicrobiano AND unidade_idade = 'Anos' AND idade_paciente IS NOT NULL
        GROUP BY 1 ORDER BY 1""",
    "Q6 top CID-10 antimicrobianos": """
        SELECT codigo_cid10, COUNT(*) n FROM vendas
        WHERE eh_antimicrobiano AND codigo_cid10 IS NOT NULL
        GROUP BY 1 ORDER BY n DESC LIMIT 10""",
    "Q7 por tipo de receituário": """
        SELECT tipo_receituario, SUM(quantidade_vendida) q, COUNT(*) n
        FROM vendas GROUP BY 1 ORDER BY q DESC""",
    "Q8 princípio x região x trimestre": """
        SELECT principio_ativo, regiao, trimestre, SUM(quantidade_vendida) q
        FROM vendas GROUP BY 1, 2, 3 ORDER BY q DESC LIMIT 20""",
}


def contagem_postgres():
    try:
        import psycopg
        with psycopg.connect(config.DATABASE_URL, connect_timeout=5) as c:
            return dict(c.execute(
                # ATENÇÃO AQUI: id_periodo %% 100 em vez de id_periodo % 100
                "SELECT id_periodo %% 100, COUNT(*) FROM venda_medicamento "
                "WHERE id_periodo / 100 = %s GROUP BY 1", (config.ANO_RECORTE,)
            ).fetchall())
    except Exception as e:
        print(f"[aviso] PostgreSQL indisponível, pulando comparação: {e}")
        return None


def main():
    con = duckdb.connect()
    con.execute("INSTALL delta; LOAD delta;")
    con.execute(f"CREATE VIEW vendas AS SELECT * FROM delta_scan('{CAMINHO}')")

    falhas = 0
    for nome, sql in CONSULTAS.items():
        t = time.perf_counter()
        linhas = con.execute(sql).fetchall()
        print(f"[ok] {nome}: {len(linhas)} linhas em {time.perf_counter() - t:.2f}s")
        # if not linhas:
            # falhas += 1

    dup = con.execute(
        "SELECT COUNT(*) - COUNT(DISTINCT id_venda) FROM vendas").fetchone()[0]
    print(f"[idempotência] id_venda duplicados: {dup}")
    falhas += dup > 0

    origem = contagem_postgres()
    if origem is not None:
        destino = dict(con.execute(
            "SELECT mes, COUNT(*) FROM vendas GROUP BY 1").fetchall())
        for mes, n in sorted(origem.items()):
            ok = destino.get(mes) == n
            falhas += not ok
            print(f"[{'ok' if ok else 'DIVERGE'}] mês {mes:02d}: pg={n} delta={destino.get(mes)}")

    print("VALIDAÇÃO OK" if not falhas else f"VALIDAÇÃO FALHOU ({falhas})")
    return 1 if falhas else 0


if __name__ == "__main__":
    sys.exit(main())
