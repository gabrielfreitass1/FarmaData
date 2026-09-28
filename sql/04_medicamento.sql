-- Etapa 3: Medicamentos industrializados (princípio ativo + apresentação)

CREATE TABLE IF NOT EXISTS medicamento (
    id_medicamento         BIGSERIAL PRIMARY KEY,
    principio_ativo        TEXT      NOT NULL,
    descricao_apresentacao TEXT      NOT NULL,
    CONSTRAINT uq_medicamento_ativo_apresentacao UNIQUE (principio_ativo, descricao_apresentacao)
);

COMMENT ON TABLE medicamento IS 'Catálogo de medicamentos industrializados dispensados (controlados e antimicrobianos)';

CREATE INDEX IF NOT EXISTS idx_medicamento_principio_ativo ON medicamento(principio_ativo);
