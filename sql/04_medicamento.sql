-- ============================================================================
-- Etapa 3: Medicamento - Tabela de Medicamentos Industrializados
-- Descrição: Estrutura normalizada (princípio ativo + apresentação comercial)
-- ============================================================================

CREATE TABLE IF NOT EXISTS medicamento (
    id_medicamento BIGSERIAL PRIMARY KEY,
    principio_ativo TEXT NOT NULL,
    descricao_apresentacao TEXT NOT NULL,
    CONSTRAINT uq_medicamento_ativo_apresentacao UNIQUE (principio_ativo, descricao_apresentacao)
);

COMMENT ON TABLE medicamento IS 'Catálogo de medicamentos industrializados dispensados (controlados e antimicrobianos)';
COMMENT ON COLUMN medicamento.id_medicamento IS 'Chave primária sintética do medicamento';
COMMENT ON COLUMN medicamento.principio_ativo IS 'Substância ativa ou associação (separada por +) regulamentada pela Anvisa';
COMMENT ON COLUMN medicamento.descricao_apresentacao IS 'Forma farmacêutica, concentração e embalagem (ex: 500 MG COM REV CT BL AL PLAS)';

CREATE INDEX IF NOT EXISTS idx_medicamento_principio_ativo ON medicamento(principio_ativo);
CREATE INDEX IF NOT EXISTS idx_medicamento_busca_trgm ON medicamento USING gin (principio_ativo gin_trgm_ops) 
    WHERE false; -- Suporte documentado para extensão pg_trgm caso ativada
