-- Etapa 7: População por faixa etária e município (IBGE/SIDRA, Censo 2022, tabela 9514)
-- Estrutura; populada por scripts/carregar_ibge_faixa_etaria.js após carregar_ibge_populacao.js
-- (depende de municipio.codigo_ibge).

CREATE TABLE IF NOT EXISTS ibge_populacao_faixa_etaria_municipio (
    id_municipio  INT  NOT NULL REFERENCES municipio(id_municipio),
    ano           INT  NOT NULL CHECK (ano BETWEEN 2000 AND 2100),
    faixa_etaria  TEXT NOT NULL,
    populacao     INT  NOT NULL CHECK (populacao >= 0),
    PRIMARY KEY (id_municipio, ano, faixa_etaria)
);

COMMENT ON TABLE ibge_populacao_faixa_etaria_municipio IS 'População por município/faixa etária/ano (IBGE/SIDRA, Censo 2022, tabela 9514) — usada para cruzar com idade_paciente dos antimicrobianos';
