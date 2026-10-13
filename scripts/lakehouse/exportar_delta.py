"""Exporta venda_medicamento (OLTP/PostgreSQL) para tabela Delta Lake sobre Parquet.

Idempotente: cada mês é gravado com overwrite restrito à própria partição
(predicate ano/mes), então reexecutar não duplica linhas.

Uso: python scripts/lakehouse/exportar_delta.py [--meses 1,2,3]
"""
import argparse
import sys

import psycopg
import pyarrow as pa
import pyarrow.compute as pc
from deltalake import DeltaTable, write_deltalake

import config

SCHEMA = pa.schema([
    ("id_venda", pa.int64()),
    ("data_venda", pa.date32()),
    ("ano", pa.int32()),
    ("mes", pa.int32()),
    ("trimestre", pa.int32()),
    ("id_municipio", pa.int32()),
    ("nome_municipio", pa.string()),
    ("sigla_uf", pa.string()),
    ("regiao", pa.string()),
    ("id_medicamento", pa.int64()),
    ("principio_ativo", pa.string()),
    ("tipo_receituario", pa.string()),
    ("quantidade_vendida", pa.float64()),
    ("unidade_medida", pa.string()),
    ("codigo_cid10", pa.string()),
    ("sexo_paciente", pa.string()),
    ("idade_paciente", pa.int16()),
    ("unidade_idade", pa.string()),
    ("eh_antimicrobiano", pa.bool_()),
    ("arquivo_origem", pa.string()),
])

SQL_MES = """
SELECT v.id_venda, v.data_venda, p.ano, p.mes, p.trimestre,
       v.id_municipio, mu.nome_municipio, mu.sigla_uf, uf.regiao,
       v.id_medicamento, m.principio_ativo, tr.descricao,
       v.quantidade_vendida::float8, um.descricao,
       v.codigo_cid10, v.sexo_paciente, v.idade_paciente, ui.descricao,
       v.eh_antimicrobiano, v.arquivo_origem
FROM venda_medicamento v
JOIN periodo p             ON p.id_periodo = v.id_periodo
JOIN municipio mu          ON mu.id_municipio = v.id_municipio
JOIN unidade_federativa uf ON uf.sigla = mu.sigla_uf
JOIN medicamento m         ON m.id_medicamento = v.id_medicamento
LEFT JOIN tipo_receituario tr ON tr.id_tipo_receituario = v.id_tipo_receituario
LEFT JOIN unidade_medida um   ON um.id_unidade_medida = v.id_unidade_medida
LEFT JOIN unidade_idade ui    ON ui.id_unidade_idade = v.id_unidade_idade
WHERE v.id_periodo = %s
{ordem}
"""

ORDEM = ""  # sobrescrito no commit de particionamento


def lotes_do_mes(conn, id_periodo):
    """Gera RecordBatches lendo o mês via cursor de servidor (memória constante)."""
    nomes = SCHEMA.names
    with conn.cursor(name=f"exp_{id_periodo}") as cur:
        cur.itersize = config.LOTE_LEITURA_PG
        cur.execute(SQL_MES.format(ordem=ORDEM), (id_periodo,))
        while True:
            linhas = cur.fetchmany(config.LOTE_LEITURA_PG)
            if not linhas:
                break
            colunas = list(zip(*linhas))
            yield pa.RecordBatch.from_arrays(
                [pa.array(c, type=SCHEMA.field(n).type) for n, c in zip(nomes, colunas)],
                schema=SCHEMA,
            )


def opcoes_escrita():
    return {}


def exportar_mes(conn, ano, mes):
    id_periodo = ano * 100 + mes
    leitor = pa.RecordBatchReader.from_batches(SCHEMA, lotes_do_mes(conn, id_periodo))
    existe = DeltaTable.is_deltatable(config.TABELA_VENDAS)
    write_deltalake(
        config.TABELA_VENDAS,
        leitor,
        partition_by=config.PARTICOES,
        mode="overwrite",
        # Overwrite restrito à partição => reprocessar o mês substitui, não duplica.
        predicate=f"ano = {ano} AND mes = {mes}" if existe else None,
        engine="rust",
        **opcoes_escrita(),
    )
    n = DeltaTable(config.TABELA_VENDAS).to_pyarrow_dataset().count_rows(
        filter=(pc.field("ano") == ano) & (pc.field("mes") == mes)
    )
    print(f"[delta] {ano}-{mes:02d}: {n} linhas na partição")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--meses", default=",".join(str(m) for m in range(1, 13)))
    args = ap.parse_args()
    meses = [int(m) for m in args.meses.split(",")]
    with psycopg.connect(config.DATABASE_URL) as conn:
        for mes in meses:
            exportar_mes(conn, config.ANO_RECORTE, mes)
    print(f"[delta] versão atual: {DeltaTable(config.TABELA_VENDAS).version()}")


if __name__ == "__main__":
    sys.exit(main())
