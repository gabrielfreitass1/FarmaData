-- Etapa 6: População estimada por município (IBGE/SIDRA, tabela 6579)
-- Estrutura; populada por scripts/carregar_ibge_populacao.js após a carga do SNGPC
-- (depende de municipio.codigo_ibge, preenchido pelo mesmo script).

CREATE TABLE IF NOT EXISTS ibge_populacao_municipio (
    id_municipio INT NOT NULL REFERENCES municipio(id_municipio),
    ano          INT NOT NULL CHECK (ano BETWEEN 2000 AND 2100),
    populacao    INT NOT NULL CHECK (populacao >= 0),
    PRIMARY KEY (id_municipio, ano)
);

COMMENT ON TABLE ibge_populacao_municipio IS 'População estimada por município/ano (IBGE/SIDRA, tabela 6579) — usada para normalizar volume de venda per capita';
