"""Benchmark antes/depois do layout Parquet (issue #6).

Gera um layout "ingênuo" (Snappy, partições por ano/mes/UF, arquivos de no
máximo 50 mil linhas, sem ordenação — o padrão "um arquivo por lote") a partir
da tabela Delta e compara com o layout otimizado em:
  - número de arquivos, tamanho em disco
  - tempo de 3 consultas de referência no DuckDB (mediana de N execuções)

Uso: python scripts/lakehouse/benchmark_layout.py [--repeticoes 5]
Resultados vão para data/lakehouse/benchmark.md (cole em docs/CAMADA_ANALITICA.md).
"""
import argparse
import os
import shutil
import statistics
import time

import duckdb
import pyarrow.dataset as ds
from deltalake import DeltaTable

import config

INGENUO = os.path.join(config.LAKEHOUSE_DIR, "bench_ingenuo")

CONSULTAS = {
    "Q3 evolução mensal": "SELECT mes, SUM(quantidade_vendida) FROM {t} GROUP BY 1",
    "Q8 princípio x região x trimestre":
        "SELECT principio_ativo, regiao, trimestre, SUM(quantidade_vendida) q "
        "FROM {t} GROUP BY 1,2,3 ORDER BY q DESC LIMIT 20",
    "Filtro UF+mês (DF, março)":
        "SELECT principio_ativo, SUM(quantidade_vendida) FROM {t} "
        "WHERE sigla_uf = 'DF' AND mes = 3 GROUP BY 1",
}


def tamanho(arquivos):
    return sum(os.path.getsize(a) for a in arquivos) / 1024 ** 2


def gerar_ingenuo():
    shutil.rmtree(INGENUO, ignore_errors=True)
    origem = DeltaTable(config.TABELA_VENDAS).to_pyarrow_dataset()
    ds.write_dataset(
        origem, INGENUO, format="parquet",
        partitioning=["ano", "mes", "sigla_uf"], partitioning_flavor="hive",
        file_options=ds.ParquetFileFormat().make_write_options(compression="snappy"),
        max_rows_per_file=50_000, max_rows_per_group=50_000,
        existing_data_behavior="overwrite_or_ignore",
    )


def medir(con, tabela, repeticoes):
    res = {}
    for nome, sql in CONSULTAS.items():
        tempos = []
        for _ in range(repeticoes):
            t = time.perf_counter()
            con.execute(sql.format(t=tabela)).fetchall()
            tempos.append(time.perf_counter() - t)
        res[nome] = statistics.median(tempos)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repeticoes", type=int, default=5)
    args = ap.parse_args()

    gerar_ingenuo()
    dt = DeltaTable(config.TABELA_VENDAS)
    arq_otim = [os.path.join(config.TABELA_VENDAS, f) for f in dt.files()]
    arq_ing = [os.path.join(r, f) for r, _, fs in os.walk(INGENUO) for f in fs
               if f.endswith(".parquet")]

    con = duckdb.connect()
    con.execute("INSTALL delta; LOAD delta;")
    otim = os.path.abspath(config.TABELA_VENDAS).replace("\\", "/")
    ing = os.path.abspath(INGENUO).replace("\\", "/")
    t_otim = medir(con, f"delta_scan('{otim}')", args.repeticoes)
    t_ing = medir(con, f"read_parquet('{ing}/**/*.parquet', hive_partitioning=true)",
                  args.repeticoes)

    linhas = [
        "| Métrica | Ingênuo (Snappy, ano/mes/UF, 50k linhas/arquivo) | Otimizado (ZSTD-3, ano/mes, ordenado, compactado) |",
        "|---|---|---|",
        f"| Arquivos Parquet | {len(arq_ing)} | {len(arq_otim)} |",
        f"| Tamanho em disco (MB) | {tamanho(arq_ing):.1f} | {tamanho(arq_otim):.1f} |",
    ]
    linhas += [f"| {n} (s, mediana de {args.repeticoes}) | {t_ing[n]:.3f} | {t_otim[n]:.3f} |"
               for n in CONSULTAS]
    saida = "\n".join(linhas)
    print(saida)
    with open(os.path.join(config.LAKEHOUSE_DIR, "benchmark.md"), "w", encoding="utf-8") as f:
        f.write(saida + "\n")
    shutil.rmtree(INGENUO, ignore_errors=True)


if __name__ == "__main__":
    main()
