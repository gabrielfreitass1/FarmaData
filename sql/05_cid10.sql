-- ============================================================================
-- Etapa 3: CID-10 - Tabela de Classificação Internacional de Doenças
-- Descrição: Catálogo oficial de doenças da OMS / DATASUS (usado em antimicrobianos)
-- ============================================================================

CREATE TABLE IF NOT EXISTS cid10 (
    codigo VARCHAR(10) PRIMARY KEY, -- Código alfanumérico (ex: A00, A499, J010)
    descricao TEXT NOT NULL,
    descricao_abreviada VARCHAR(120),
    categoria VARCHAR(4),
    restricao_sexo CHAR(1), -- 'M', 'F' ou NULL se sem restrição
    causa_obito CHAR(1)     -- 'S', 'N'
);

COMMENT ON TABLE cid10 IS 'Catálogo oficial de doenças e agravos CID-10 do DATASUS';
COMMENT ON COLUMN cid10.codigo IS 'Código oficial da subcategoria ou categoria CID-10 sem pontos (ex: A499)';
COMMENT ON COLUMN cid10.descricao IS 'Descrição clínica completa do diagnóstico';
COMMENT ON COLUMN cid10.descricao_abreviada IS 'Descrição abreviada padrão DATASUS (até 50 caracteres)';
COMMENT ON COLUMN cid10.categoria IS 'Código de 3 caracteres da categoria de agrupamento';

CREATE INDEX IF NOT EXISTS idx_cid10_categoria ON cid10(categoria);
CREATE INDEX IF NOT EXISTS idx_cid10_descricao ON cid10(descricao);
