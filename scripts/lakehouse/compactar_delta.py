"""Compacta arquivos pequenos da tabela Delta (small files problem) e remove
arquivos órfãos de versões antigas.

Uso: python scripts/lakehouse/compactar_delta.py [--manter-horas 168]
"""
import argparse

from deltalake import DeltaTable, WriterProperties

import config


def resumo(dt):
    arquivos = dt.files()
    return len(arquivos)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manter-horas", type=int, default=168,
                    help="retenção para time travel antes do vacuum")
    args = ap.parse_args()

    dt = DeltaTable(config.TABELA_VENDAS)
    antes = resumo(dt)
    metricas = dt.optimize.compact(
        target_size=config.TAMANHO_ALVO_COMPACTACAO,
        writer_properties=WriterProperties(
            compression=config.CODEC,
            compression_level=config.NIVEL_CODEC,
            max_row_group_size=config.LINHAS_POR_ROW_GROUP,
        ),
    )
    dt = DeltaTable(config.TABELA_VENDAS)
    print(f"[compact] arquivos ativos: {antes} -> {resumo(dt)}")
    print(f"[compact] métricas: {metricas}")

    removidos = dt.vacuum(retention_hours=args.manter_horas,
                          enforce_retention_duration=False, dry_run=False)
    print(f"[vacuum] {len(removidos)} arquivos fora de uso removidos")


if __name__ == "__main__":
    main()
