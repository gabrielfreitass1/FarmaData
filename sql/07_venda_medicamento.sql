-- ============================================================================
-- Etapa 5: Tabela Principal — Fato de Vendas de Medicamentos (SNGPC)
-- Descrição: Tabela central onde cada linha representa uma dispensação.
--            Campos de CID-10, sexo e idade do paciente são exclusivos de
--            antimicrobianos — aceitam NULL para os demais medicamentos.
-- ============================================================================

CREATE TABLE IF NOT EXISTS venda_medicamento (
    id_venda             BIGSERIAL PRIMARY KEY,

    -- Dimensão temporal
    id_periodo           INT          NOT NULL
                         REFERENCES periodo(id_periodo),
    data_venda           DATE         NOT NULL,

    -- Dimensão geográfica
    id_municipio         INT          NOT NULL
                         REFERENCES municipio(id_municipio),

    -- Dimensão do produto
    id_medicamento       BIGINT       NOT NULL
                         REFERENCES medicamento(id_medicamento),

    -- Dimensão da prescrição
    id_conselho          SMALLINT
                         REFERENCES conselho_profissional(id_conselho),
    id_tipo_receituario  SMALLINT
                         REFERENCES tipo_receituario(id_tipo_receituario),

    -- Quantidade dispensada
    quantidade_vendida   NUMERIC(10,3) NOT NULL CHECK (quantidade_vendida > 0),
    id_unidade_medida    SMALLINT
                         REFERENCES unidade_medida(id_unidade_medida),

    -- Campos exclusivos de antimicrobianos (NULL para demais medicamentos)
    codigo_cid10         VARCHAR(10)
                         REFERENCES cid10(codigo),
    sexo_paciente        CHAR(1)
                         CHECK (sexo_paciente IN ('M', 'F') OR sexo_paciente IS NULL),
    idade_paciente       SMALLINT
                         CHECK (idade_paciente >= 0 OR idade_paciente IS NULL),
    id_unidade_idade     SMALLINT
                         REFERENCES unidade_idade(id_unidade_idade),

    -- Flag que distingue antimicrobiano de controlado
    eh_antimicrobiano    BOOLEAN      NOT NULL DEFAULT FALSE,

    -- Rastreabilidade da carga
    numero_notificacao   VARCHAR(30),
    arquivo_origem       VARCHAR(80),

    -- Constraint: campos de antimicrobiano devem ser todos preenchidos ou todos nulos
    CONSTRAINT chk_antimicrobiano_campos CHECK (
        (eh_antimicrobiano = FALSE AND codigo_cid10 IS NULL AND sexo_paciente IS NULL AND idade_paciente IS NULL)
        OR
        (eh_antimicrobiano = TRUE)
    )
);

COMMENT ON TABLE venda_medicamento IS 'Tabela fato central: cada linha é uma dispensação de medicamento controlado ou antimicrobiano registrada no SNGPC/Anvisa';
COMMENT ON COLUMN venda_medicamento.id_venda IS 'Chave primária sintética da dispensação';
COMMENT ON COLUMN venda_medicamento.id_periodo IS 'Referência à dimensão de tempo (ano/mês da competência)';
COMMENT ON COLUMN venda_medicamento.data_venda IS 'Data exata da dispensação';
COMMENT ON COLUMN venda_medicamento.id_municipio IS 'Município onde a dispensação ocorreu';
COMMENT ON COLUMN venda_medicamento.id_medicamento IS 'Medicamento dispensado (princípio ativo + apresentação)';
COMMENT ON COLUMN venda_medicamento.id_conselho IS 'Conselho profissional do prescritor';
COMMENT ON COLUMN venda_medicamento.id_tipo_receituario IS 'Tipo de receituário (A, B1, B2, C1, D)';
COMMENT ON COLUMN venda_medicamento.quantidade_vendida IS 'Quantidade dispensada na unidade de medida informada';
COMMENT ON COLUMN venda_medicamento.id_unidade_medida IS 'Unidade de medida da quantidade (caixa, frasco etc.)';
COMMENT ON COLUMN venda_medicamento.codigo_cid10 IS 'Código CID-10 do diagnóstico — somente para antimicrobianos';
COMMENT ON COLUMN venda_medicamento.sexo_paciente IS 'Sexo biológico do paciente (M/F) — somente para antimicrobianos';
COMMENT ON COLUMN venda_medicamento.idade_paciente IS 'Idade do paciente — somente para antimicrobianos';
COMMENT ON COLUMN venda_medicamento.id_unidade_idade IS 'Unidade da idade (Anos/Meses) — somente para antimicrobianos';
COMMENT ON COLUMN venda_medicamento.eh_antimicrobiano IS 'TRUE se o registro provém dos arquivos de antimicrobianos da Anvisa';
COMMENT ON COLUMN venda_medicamento.numero_notificacao IS 'Número da notificação de receita (rastreabilidade)';
COMMENT ON COLUMN venda_medicamento.arquivo_origem IS 'Nome do arquivo CSV fonte da dispensação (auditoria)';

-- ----------------------------------------------------------------------------
-- Índices para consultas típicas por data, medicamento e município
-- ----------------------------------------------------------------------------

-- Consultas por período (agregação mensal / anual)
CREATE INDEX IF NOT EXISTS idx_venda_periodo
    ON venda_medicamento(id_periodo);

-- Consultas por data exata (filtros de intervalo)
CREATE INDEX IF NOT EXISTS idx_venda_data
    ON venda_medicamento(data_venda);

-- Consultas por medicamento (ranking de princípio ativo)
CREATE INDEX IF NOT EXISTS idx_venda_medicamento
    ON venda_medicamento(id_medicamento);

-- Consultas por município (mapa geográfico)
CREATE INDEX IF NOT EXISTS idx_venda_municipio
    ON venda_medicamento(id_municipio);

-- Índice composto: município + período (padrão de acesso mais comum em dashboards)
CREATE INDEX IF NOT EXISTS idx_venda_municipio_periodo
    ON venda_medicamento(id_municipio, id_periodo);

-- Índice composto: medicamento + período (série temporal por princípio ativo)
CREATE INDEX IF NOT EXISTS idx_venda_medicamento_periodo
    ON venda_medicamento(id_medicamento, id_periodo);

-- Índice filtrado: apenas antimicrobianos (subconjunto frequente de análise)
CREATE INDEX IF NOT EXISTS idx_venda_antimicrobiano
    ON venda_medicamento(id_periodo, id_municipio)
    WHERE eh_antimicrobiano = TRUE;
