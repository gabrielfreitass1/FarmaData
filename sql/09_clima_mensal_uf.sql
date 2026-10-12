-- Etapa 6: Clima mensal por UF (INMET, dados históricos por estação)
-- Estrutura; populada por scripts/carregar_inmet.js.
-- Granularidade por UF (não município): estações cobrem só parte dos municípios.

CREATE TABLE IF NOT EXISTS clima_mensal_uf (
    sigla_uf              CHAR(2)       NOT NULL REFERENCES unidade_federativa(sigla),
    id_periodo            INT           NOT NULL REFERENCES periodo(id_periodo),
    temp_media_c          NUMERIC(5,2),
    precipitacao_media_mm NUMERIC(10,2),
    qtd_estacoes          SMALLINT      NOT NULL CHECK (qtd_estacoes >= 0),
    PRIMARY KEY (sigla_uf, id_periodo)
);

COMMENT ON TABLE clima_mensal_uf IS 'Temperatura e precipitação médias por UF/mês (INMET) — média entre as estações da UF com dados no mês';
