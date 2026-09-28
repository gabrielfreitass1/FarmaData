-- ============================================================================
-- Etapa 2: Geografia - Tabela de Municípios
-- Descrição: Estrutura da tabela de municípios (populada a partir dos dados do SNGPC)
-- ============================================================================

CREATE TABLE IF NOT EXISTS municipio (
    id_municipio SERIAL PRIMARY KEY,
    nome_municipio VARCHAR(150) NOT NULL,
    sigla_uf CHAR(2) NOT NULL REFERENCES unidade_federativa(sigla) ON UPDATE CASCADE,
    codigo_ibge INT,
    CONSTRAINT uq_municipio_nome_uf UNIQUE (nome_municipio, sigla_uf)
);

COMMENT ON TABLE municipio IS 'Municípios onde ocorreram as dispensações de medicamentos no Brasil';
COMMENT ON COLUMN municipio.id_municipio IS 'Identificador sintético do município no sistema';
COMMENT ON COLUMN municipio.nome_municipio IS 'Nome oficial do município registrado na venda';
COMMENT ON COLUMN municipio.sigla_uf IS 'Sigla da Unidade Federativa a que pertence o município';
COMMENT ON COLUMN municipio.codigo_ibge IS 'Código IBGE de 7 dígitos do município (quando enriquecido)';

CREATE INDEX IF NOT EXISTS idx_municipio_sigla_uf ON municipio(sigla_uf);
CREATE INDEX IF NOT EXISTS idx_municipio_nome ON municipio(nome_municipio);
