-- ============================================================================
-- Etapa 2: Geografia - Tabela de Unidades Federativas (UF)
-- Descrição: Estrutura da tabela e inserção estática das 27 unidades federativas
-- ============================================================================

CREATE TABLE IF NOT EXISTS unidade_federativa (
    sigla CHAR(2) PRIMARY KEY,
    codigo_ibge INT NOT NULL UNIQUE,
    nome VARCHAR(50) NOT NULL,
    regiao VARCHAR(20) NOT NULL
);

COMMENT ON TABLE unidade_federativa IS 'Lista fixa e padronizada das 27 Unidades da Federação do Brasil';
COMMENT ON COLUMN unidade_federativa.sigla IS 'Sigla da UF com 2 caracteres (ex: SP, RJ, DF)';
COMMENT ON COLUMN unidade_federativa.codigo_ibge IS 'Código IBGE de 2 dígitos da UF';
COMMENT ON COLUMN unidade_federativa.nome IS 'Nome por extenso da UF';
COMMENT ON COLUMN unidade_federativa.regiao IS 'Grande região geográfica do Brasil';

INSERT INTO unidade_federativa (sigla, codigo_ibge, nome, regiao) VALUES
('RO', 11, 'Rondônia', 'Norte'),
('AC', 12, 'Acre', 'Norte'),
('AM', 13, 'Amazonas', 'Norte'),
('RR', 14, 'Roraima', 'Norte'),
('PA', 15, 'Pará', 'Norte'),
('AP', 16, 'Amapá', 'Norte'),
('TO', 17, 'Tocantins', 'Norte'),
('MA', 21, 'Maranhão', 'Nordeste'),
('PI', 22, 'Piauí', 'Nordeste'),
('CE', 23, 'Ceará', 'Nordeste'),
('RN', 24, 'Rio Grande do Norte', 'Nordeste'),
('PB', 25, 'Paraíba', 'Nordeste'),
('PE', 26, 'Pernambuco', 'Nordeste'),
('AL', 27, 'Alagoas', 'Nordeste'),
('SE', 28, 'Sergipe', 'Nordeste'),
('BA', 29, 'Bahia', 'Nordeste'),
('MG', 31, 'Minas Gerais', 'Sudeste'),
('ES', 32, 'Espírito Santo', 'Sudeste'),
('RJ', 33, 'Rio de Janeiro', 'Sudeste'),
('SP', 35, 'São Paulo', 'Sudeste'),
('PR', 41, 'Paraná', 'Sul'),
('SC', 42, 'Santa Catarina', 'Sul'),
('RS', 43, 'Rio Grande do Sul', 'Sul'),
('MS', 50, 'Mato Grosso do Sul', 'Centro-Oeste'),
('MT', 51, 'Mato Grosso', 'Centro-Oeste'),
('GO', 52, 'Goiás', 'Centro-Oeste'),
('DF', 53, 'Distrito Federal', 'Centro-Oeste')
ON CONFLICT (sigla) DO UPDATE 
SET codigo_ibge = EXCLUDED.codigo_ibge,
    nome = EXCLUDED.nome,
    regiao = EXCLUDED.regiao;
