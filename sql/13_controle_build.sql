CREATE TABLE IF NOT EXISTS controle_build (
    tabela        TEXT        NOT NULL,
    construido_em TIMESTAMPTZ NOT NULL DEFAULT now(),
    linhas        BIGINT,
    PRIMARY KEY (tabela, construido_em)
);
COMMENT ON TABLE controle_build IS 'Carimbo de cada reconstrução de tabela de consumo; base do freshness (issue #29)';

CREATE OR REPLACE FUNCTION registrar_build(p_tabela TEXT, p_linhas BIGINT DEFAULT NULL)
RETURNS VOID AS $$
    INSERT INTO controle_build (tabela, linhas) VALUES (p_tabela, p_linhas);
$$ LANGUAGE sql;

-- Freshness: existe carga mais nova que a última construção da tabela?
-- OK   = nenhuma carga depois da última construção (ou carga pendente há menos de p_warn_h)
-- WARN = carga pendente há mais de p_warn_h horas
-- ERRO = carga pendente há mais de p_erro_h horas, ou tabela nunca construída
-- Fonte única da regra: usada por scripts/checar_freshness.sh e pela DAG farmadata_freshness.
-- carga_arquivo é criada pela carga (scripts/carregar_sngpc.js), não por sql/: se ainda
-- não existe, conta como "nenhuma carga".
CREATE OR REPLACE FUNCTION checar_freshness(p_tabela TEXT, p_warn_h INT DEFAULT 24, p_erro_h INT DEFAULT 48)
RETURNS TABLE(status TEXT, ultima_carga TIMESTAMPTZ, ultimo_build TIMESTAMPTZ) AS $$
DECLARE
    v_carga TIMESTAMPTZ;
    v_build TIMESTAMPTZ;
BEGIN
    IF to_regclass('carga_arquivo') IS NOT NULL THEN
        EXECUTE 'SELECT max(carregado_em) FROM carga_arquivo' INTO v_carga;
    END IF;
    SELECT max(cb.construido_em) INTO v_build FROM controle_build cb WHERE cb.tabela = p_tabela;

    status := CASE
        WHEN v_build IS NULL THEN 'ERRO'
        WHEN v_carga IS NULL OR v_carga <= v_build THEN 'OK'
        WHEN now() - v_carga > make_interval(hours => p_erro_h) THEN 'ERRO'
        WHEN now() - v_carga > make_interval(hours => p_warn_h) THEN 'WARN'
        ELSE 'OK' END;
    ultima_carga := v_carga;
    ultimo_build := v_build;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION checar_freshness IS 'Status de freshness (OK/WARN/ERRO) de uma tabela de consumo frente à última carga (issue #29)';
