-- Etapa 8 (E3): Modelo dimensional — dimensão de variação lenta (SCD Tipo 2)
-- de município + dimensões conformadas (views finas sobre tabelas já
-- normalizadas). Chaves substitutas são hash md5 determinístico.
--
-- Município é a entidade mutável: IBGE pode renomear ou alterar os limites
-- de um município ao longo do tempo. As demais dimensões (tempo, medicamento,
-- conselho, tipo de receituário, unidade de medida) são publicações oficiais
-- imutáveis — não precisam de versionamento, só de uma surrogate key.

-- Fórmula única de surrogate key: evita a mesma lógica (md5 do nome da
-- dimensão + chave natural) reimplementada e podendo divergir em cada
-- view/INSERT que a usa (sql/11 e sql/12).
-- Retorna TEXT (não CHAR/bpchar): md5() já devolve TEXT, e CREATE OR REPLACE
-- VIEW não pode trocar o tipo de uma coluna existente — um sk_hash() com tipo
-- de retorno diferente do md5() original quebraria o upgrade das views em
-- qualquer banco que já as tivesse. As colunas de tabela (CHAR(32)) seguem
-- recebendo o valor normalmente via cast de atribuição no INSERT.
CREATE OR REPLACE FUNCTION sk_hash(p_dimensao TEXT, p_chave_natural ANYELEMENT)
RETURNS TEXT AS $$
    SELECT md5(p_dimensao || '|' || p_chave_natural);
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION sk_hash IS 'Surrogate key determinística (md5) de uma dimensão a partir da chave natural — fonte única usada por todas as dim_* e pela fato';

CREATE TABLE IF NOT EXISTS dim_municipio (
    sk_municipio   CHAR(32)     PRIMARY KEY,
    id_municipio   INT          NOT NULL REFERENCES municipio(id_municipio),
    nome_municipio VARCHAR(150) NOT NULL,
    sigla_uf       CHAR(2)      NOT NULL,
    regiao         VARCHAR(20)  NOT NULL,
    codigo_ibge    INT,
    valid_from     DATE         NOT NULL,
    valid_to       DATE,
    is_current     BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_dim_municipio_versao UNIQUE (id_municipio, valid_from)
);

COMMENT ON TABLE dim_municipio IS 'Dimensão de variação lenta (SCD Tipo 2) de município: versiona alterações territoriais/renomeações preservando o histórico anterior';

-- Garante no máximo 1 linha corrente por município (chave natural).
CREATE UNIQUE INDEX IF NOT EXISTS uq_dim_municipio_corrente
    ON dim_municipio (id_municipio) WHERE is_current;

CREATE INDEX IF NOT EXISTS idx_dim_municipio_natural ON dim_municipio(id_municipio);

-- Aplica o merge SCD2: para cada município de origem, abre a primeira versão
-- (valid_from sentinela '1900-01-01', cobre qualquer venda histórica) ou,
-- se os atributos versionados mudaram, fecha a versão corrente e abre uma nova.
-- Idempotente: reexecutar sem mudanças na origem não altera nada.
CREATE OR REPLACE FUNCTION aplicar_scd2_municipio(p_data_efetiva DATE DEFAULT CURRENT_DATE)
RETURNS TABLE(municipios_novos INT, municipios_versionados INT) AS $$
DECLARE
    v_novos INT := 0;
    v_versionados INT := 0;
BEGIN
    -- Município ainda sem nenhuma versão na dimensão: abre a primeira.
    INSERT INTO dim_municipio (sk_municipio, id_municipio, nome_municipio, sigla_uf, regiao, codigo_ibge, valid_from, valid_to, is_current)
    SELECT
        sk_hash('municipio', mu.id_municipio || '|' || DATE '1900-01-01'),
        mu.id_municipio, mu.nome_municipio, mu.sigla_uf, uf.regiao, mu.codigo_ibge,
        DATE '1900-01-01', NULL, TRUE
    FROM municipio mu
    JOIN unidade_federativa uf ON uf.sigla = mu.sigla_uf
    WHERE NOT EXISTS (SELECT 1 FROM dim_municipio dm WHERE dm.id_municipio = mu.id_municipio);
    GET DIAGNOSTICS v_novos = ROW_COUNT;

    -- Município com versão corrente cujos atributos mudaram: fecha a corrente
    -- (preservando a linha antiga, sem perda de histórico) antes de abrir a nova
    -- — dois comandos sequenciais, não dois CTEs do mesmo WITH (que não veem o
    -- efeito um do outro e violariam o índice único de linha corrente).
    UPDATE dim_municipio dm
    SET valid_to = p_data_efetiva, is_current = FALSE
    FROM municipio mu
    JOIN unidade_federativa uf ON uf.sigla = mu.sigla_uf
    WHERE dm.id_municipio = mu.id_municipio
      AND dm.is_current
      AND (dm.nome_municipio, dm.sigla_uf, dm.regiao, dm.codigo_ibge)
          IS DISTINCT FROM (mu.nome_municipio, mu.sigla_uf, uf.regiao, mu.codigo_ibge);
    GET DIAGNOSTICS v_versionados = ROW_COUNT;

    -- ON CONFLICT: se esta função já abriu uma versão para este município
    -- hoje (duas mudanças no mesmo dia — valid_from na granularidade de
    -- DATE, não TIMESTAMP), colapsa para o estado mais recente do dia em
    -- vez de tentar criar uma segunda versão com a mesma sk_municipio.
    -- ponytail: granularidade diária, não por execução; se duas alterações
    -- reais no mesmo município no mesmo dia precisarem de versões
    -- distintas, troque valid_from/valid_to para TIMESTAMP.
    INSERT INTO dim_municipio (sk_municipio, id_municipio, nome_municipio, sigla_uf, regiao, codigo_ibge, valid_from, valid_to, is_current)
    SELECT
        sk_hash('municipio', mu.id_municipio || '|' || p_data_efetiva),
        mu.id_municipio, mu.nome_municipio, mu.sigla_uf, uf.regiao, mu.codigo_ibge,
        p_data_efetiva, NULL, TRUE
    FROM municipio mu
    JOIN unidade_federativa uf ON uf.sigla = mu.sigla_uf
    WHERE NOT EXISTS (SELECT 1 FROM dim_municipio dm_atual WHERE dm_atual.id_municipio = mu.id_municipio AND dm_atual.is_current)
    ON CONFLICT (sk_municipio) DO UPDATE
        SET nome_municipio = EXCLUDED.nome_municipio,
            sigla_uf        = EXCLUDED.sigla_uf,
            regiao          = EXCLUDED.regiao,
            codigo_ibge     = EXCLUDED.codigo_ibge,
            valid_to        = NULL,
            is_current      = TRUE;

    RETURN QUERY SELECT v_novos, v_versionados;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION aplicar_scd2_municipio IS 'Sincroniza dim_municipio (SCD2) a partir de municipio/unidade_federativa; idempotente';

-- Dimensões conformadas: views finas sobre tabelas já normalizadas e
-- imutáveis, só expondo a surrogate key determinística (sk_hash da chave natural).
CREATE OR REPLACE VIEW dim_tempo AS
SELECT sk_hash('tempo', id_periodo) AS sk_tempo, id_periodo, ano, mes, nome_mes, trimestre, semestre, data_inicio, data_fim
FROM periodo;

CREATE OR REPLACE VIEW dim_medicamento AS
SELECT sk_hash('medicamento', id_medicamento) AS sk_medicamento, id_medicamento, principio_ativo, descricao_apresentacao
FROM medicamento;

CREATE OR REPLACE VIEW dim_conselho AS
SELECT sk_hash('conselho', id_conselho) AS sk_conselho, id_conselho, sigla, descricao
FROM conselho_profissional;

CREATE OR REPLACE VIEW dim_tipo_receituario AS
SELECT sk_hash('tipo_receituario', id_tipo_receituario) AS sk_tipo_receituario, id_tipo_receituario, codigo, descricao
FROM tipo_receituario;

CREATE OR REPLACE VIEW dim_unidade_medida AS
SELECT sk_hash('unidade_medida', id_unidade_medida) AS sk_unidade_medida, id_unidade_medida, descricao
FROM unidade_medida;
