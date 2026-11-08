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