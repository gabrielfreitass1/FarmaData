-- Etapa 2: Períodos mensais (gerados dinamicamente para o ano de recorte)
-- Para trocar o ano, altere a variável 'ano_recorte' no bloco abaixo.

CREATE TABLE IF NOT EXISTS periodo (
    id_periodo  INT         PRIMARY KEY, -- YYYYMM (ex: 202001)
    ano         INT         NOT NULL CHECK (ano BETWEEN 2000 AND 2100),
    mes         INT         NOT NULL CHECK (mes BETWEEN 1 AND 12),
    nome_mes    VARCHAR(20) NOT NULL,
    trimestre   INT         NOT NULL CHECK (trimestre BETWEEN 1 AND 4),
    semestre    INT         NOT NULL CHECK (semestre BETWEEN 1 AND 2),
    data_inicio DATE        NOT NULL,
    data_fim    DATE        NOT NULL,
    CONSTRAINT uq_periodo_ano_mes UNIQUE (ano, mes)
);

COMMENT ON TABLE periodo IS 'Dimensão de tempo mensal para agregação das vendas';

DO $$
DECLARE
    ano_recorte INT := 2020;
    nomes_meses TEXT[] := ARRAY[
        'Janeiro','Fevereiro','Março','Abril','Maio','Junho',
        'Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'
    ];
    m INT;
    d_inicio DATE;
    d_fim    DATE;
BEGIN
    FOR m IN 1..12 LOOP
        d_inicio := make_date(ano_recorte, m, 1);
        d_fim    := (d_inicio + INTERVAL '1 month' - INTERVAL '1 day')::DATE;

        INSERT INTO periodo (id_periodo, ano, mes, nome_mes, trimestre, semestre, data_inicio, data_fim)
        VALUES (
            ano_recorte * 100 + m,
            ano_recorte,
            m,
            nomes_meses[m],
            CEIL(m::NUMERIC / 3)::INT,
            CASE WHEN m <= 6 THEN 1 ELSE 2 END,
            d_inicio,
            d_fim
        )
        ON CONFLICT (id_periodo) DO NOTHING;
    END LOOP;
END $$;
