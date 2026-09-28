-- Etapa 5: Tabela fato de vendas (venda_medicamento)
-- Cada linha = uma dispensação registrada no SNGPC.
-- Campos de CID-10, sexo e idade são exclusivos de antimicrobianos (NULL para demais).

CREATE TABLE IF NOT EXISTS venda_medicamento (
    id_venda             BIGSERIAL    PRIMARY KEY,

    -- Dimensões
    id_periodo           INT          NOT NULL REFERENCES periodo(id_periodo),
    data_venda           DATE         NOT NULL,
    id_municipio         INT          NOT NULL REFERENCES municipio(id_municipio),
    id_medicamento       BIGINT       NOT NULL REFERENCES medicamento(id_medicamento),
    id_conselho          SMALLINT     REFERENCES conselho_profissional(id_conselho),
    id_tipo_receituario  SMALLINT     REFERENCES tipo_receituario(id_tipo_receituario),

    -- Quantidade
    quantidade_vendida   NUMERIC(10,3) NOT NULL CHECK (quantidade_vendida > 0),
    id_unidade_medida    SMALLINT     REFERENCES unidade_medida(id_unidade_medida),

    -- Campos exclusivos de antimicrobianos
    codigo_cid10         VARCHAR(10)  REFERENCES cid10(codigo),
    sexo_paciente        CHAR(1)      CHECK (sexo_paciente IN ('M', 'F') OR sexo_paciente IS NULL),
    idade_paciente       SMALLINT     CHECK (idade_paciente >= 0 OR idade_paciente IS NULL),
    id_unidade_idade     SMALLINT     REFERENCES unidade_idade(id_unidade_idade),
    eh_antimicrobiano    BOOLEAN      NOT NULL DEFAULT FALSE,

    -- Rastreabilidade
    numero_notificacao   VARCHAR(30),
    arquivo_origem       VARCHAR(80),

    -- Garante consistência dos campos de antimicrobiano
    CONSTRAINT chk_antimicrobiano_campos CHECK (
        (eh_antimicrobiano = FALSE AND codigo_cid10 IS NULL AND sexo_paciente IS NULL AND idade_paciente IS NULL)
        OR (eh_antimicrobiano = TRUE)
    )
);

COMMENT ON TABLE venda_medicamento IS 'Tabela fato: cada linha é uma dispensação registrada no SNGPC/Anvisa';

-- Índices para os padrões de acesso mais comuns
CREATE INDEX IF NOT EXISTS idx_venda_periodo           ON venda_medicamento(id_periodo);
CREATE INDEX IF NOT EXISTS idx_venda_data              ON venda_medicamento(data_venda);
CREATE INDEX IF NOT EXISTS idx_venda_medicamento       ON venda_medicamento(id_medicamento);
CREATE INDEX IF NOT EXISTS idx_venda_municipio         ON venda_medicamento(id_municipio);
CREATE INDEX IF NOT EXISTS idx_venda_municipio_periodo ON venda_medicamento(id_municipio, id_periodo);
CREATE INDEX IF NOT EXISTS idx_venda_medicamento_periodo ON venda_medicamento(id_medicamento, id_periodo);
CREATE INDEX IF NOT EXISTS idx_venda_antimicrobiano    ON venda_medicamento(id_periodo, id_municipio)
    WHERE eh_antimicrobiano = TRUE;
