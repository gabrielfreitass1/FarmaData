-- Etapa 3: CID-10 — catálogo oficial de doenças (DATASUS/OMS)
-- Populada pelo script scripts/carregar_cid10.js

CREATE TABLE IF NOT EXISTS cid10 (
    codigo              VARCHAR(10) PRIMARY KEY, -- ex: A00, A499
    descricao           TEXT        NOT NULL,
    descricao_abreviada VARCHAR(120),
    categoria           VARCHAR(4),
    restricao_sexo      CHAR(1),                 -- 'M', 'F' ou NULL
    causa_obito         CHAR(1)                  -- 'S', 'N' ou NULL
);

COMMENT ON TABLE cid10 IS 'Catálogo CID-10 do DATASUS (subcategorias e categorias)';

CREATE INDEX IF NOT EXISTS idx_cid10_categoria ON cid10(categoria);
