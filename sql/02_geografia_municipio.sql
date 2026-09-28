-- Etapa 2: Municípios (estrutura; populada durante a carga dos CSVs)

CREATE TABLE IF NOT EXISTS municipio (
    id_municipio   SERIAL      PRIMARY KEY,
    nome_municipio VARCHAR(150) NOT NULL,
    sigla_uf       CHAR(2)     NOT NULL REFERENCES unidade_federativa(sigla) ON UPDATE CASCADE,
    codigo_ibge    INT,
    CONSTRAINT uq_municipio_nome_uf UNIQUE (nome_municipio, sigla_uf)
);

COMMENT ON TABLE municipio IS 'Municípios onde ocorreram dispensações de medicamentos';

CREATE INDEX IF NOT EXISTS idx_municipio_sigla_uf ON municipio(sigla_uf);
CREATE INDEX IF NOT EXISTS idx_municipio_nome     ON municipio(nome_municipio);
