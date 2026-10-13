"""ConfiguraÃ§Ã£o compartilhada da camada analÃ­tica (Delta Lake sobre Parquet)."""
import os

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/farmadata"
)
LAKEHOUSE_DIR = os.environ.get("LAKEHOUSE_DIR", "data/lakehouse")
TABELA_VENDAS = os.path.join(LAKEHOUSE_DIR, "delta", "venda_medicamento")
ANO_RECORTE = int(os.environ.get("ANO_RECORTE", "2020"))

# Ver docs/CAMADA_ANALITICA.md para a justificativa de cada parÃ¢metro.
PARTICOES = ["ano", "mes"]
CODEC = "ZSTD"
NIVEL_CODEC = 3
LINHAS_POR_ROW_GROUP = 500_000
TAMANHO_ALVO_COMPACTACAO = 128 * 1024 * 1024  # 128 MB
LOTE_LEITURA_PG = 200_000
