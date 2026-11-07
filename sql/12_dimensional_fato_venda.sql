-- Etapa 8 (E3): Tabela fato do modelo dimensional (esquema estrela).
-- Grão: uma linha = uma dispensação (venda) registrada no SNGPC, atribuída
-- à versão de dim_municipio vigente na data_venda (join temporal SCD2).
-- Mesmo grão de venda_medicamento — sem pré-agregação, evita dupla contagem.

CREATE TABLE IF NOT EXISTS fato_venda_medicamento (
    id_venda             BIGINT        PRIMARY KEY,

    -- Chaves substitutas (surrogate keys determinísticas, md5 da chave natural)
    sk_tempo             CHAR(32)      NOT NULL,
    sk_municipio         CHAR(32)      NOT NULL REFERENCES dim_municipio(sk_municipio),
    sk_medicamento       CHAR(32)      NOT NULL,
    sk_conselho          CHAR(32),
    sk_tipo_receituario  CHAR(32),
    sk_unidade_medida    CHAR(32),

    -- Chaves naturais (rastreabilidade até o OLTP de origem)
    id_periodo           INT           NOT NULL,
    id_municipio         INT           NOT NULL,
    id_medicamento       BIGINT        NOT NULL,
    id_conselho          SMALLINT,
    id_tipo_receituario  SMALLINT,
    id_unidade_medida    SMALLINT,

    data_venda           DATE          NOT NULL,

    -- Métrica aditiva
    quantidade_vendida   NUMERIC(10,3) NOT NULL,

    -- Atributos degenerados / contexto (antimicrobiano-only, NULL nos demais)
    codigo_cid10         VARCHAR(10),
    sexo_paciente        CHAR(1),
    idade_paciente       SMALLINT,
    id_unidade_idade     SMALLINT,
    eh_antimicrobiano    BOOLEAN       NOT NULL DEFAULT FALSE,
    numero_notificacao   VARCHAR(30),
    arquivo_origem       VARCHAR(80)
);

COMMENT ON TABLE fato_venda_medicamento IS 'Fato dimensional: 1 linha = 1 dispensação SNGPC, com surrogate keys e join temporal em dim_municipio (SCD2)';

CREATE INDEX IF NOT EXISTS idx_fato_venda_sk_tempo     ON fato_venda_medicamento(sk_tempo);
CREATE INDEX IF NOT EXISTS idx_fato_venda_sk_municipio ON fato_venda_medicamento(sk_municipio);
CREATE INDEX IF NOT EXISTS idx_fato_venda_sk_medicamento ON fato_venda_medicamento(sk_medicamento);

-- (Re)carrega a fato por completo a partir do OLTP normalizado.
-- TRUNCATE + INSERT: fato é derivada, não há custo de upsert a gerenciar.
CREATE OR REPLACE FUNCTION carregar_fato_venda_medicamento()
RETURNS BIGINT AS $$
DECLARE
    v_linhas BIGINT;
BEGIN
    TRUNCATE fato_venda_medicamento;

    INSERT INTO fato_venda_medicamento (
        id_venda, sk_tempo, sk_municipio, sk_medicamento, sk_conselho, sk_tipo_receituario, sk_unidade_medida,
        id_periodo, id_municipio, id_medicamento, id_conselho, id_tipo_receituario, id_unidade_medida,
        data_venda, quantidade_vendida,
        codigo_cid10, sexo_paciente, idade_paciente, id_unidade_idade, eh_antimicrobiano,
        numero_notificacao, arquivo_origem
    )
    SELECT
        v.id_venda,
        md5('tempo|' || v.id_periodo),
        dm.sk_municipio,
        md5('medicamento|' || v.id_medicamento),
        CASE WHEN v.id_conselho IS NOT NULL THEN md5('conselho|' || v.id_conselho) END,
        CASE WHEN v.id_tipo_receituario IS NOT NULL THEN md5('tipo_receituario|' || v.id_tipo_receituario) END,
        CASE WHEN v.id_unidade_medida IS NOT NULL THEN md5('unidade_medida|' || v.id_unidade_medida) END,
        v.id_periodo, v.id_municipio, v.id_medicamento, v.id_conselho, v.id_tipo_receituario, v.id_unidade_medida,
        v.data_venda, v.quantidade_vendida,
        v.codigo_cid10, v.sexo_paciente, v.idade_paciente, v.id_unidade_idade, v.eh_antimicrobiano,
        v.numero_notificacao, v.arquivo_origem
    FROM venda_medicamento v
    JOIN dim_municipio dm
      ON dm.id_municipio = v.id_municipio
     AND v.data_venda >= dm.valid_from
     AND v.data_venda <  COALESCE(dm.valid_to, DATE 'infinity');

    GET DIAGNOSTICS v_linhas = ROW_COUNT;
    RETURN v_linhas;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION carregar_fato_venda_medicamento IS 'Recarrega fato_venda_medicamento a partir de venda_medicamento, resolvendo dim_municipio pela versão SCD2 vigente na data_venda';
