-- Etapa 2: Períodos mensais do ano de recorte (2020)

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

INSERT INTO periodo (id_periodo, ano, mes, nome_mes, trimestre, semestre, data_inicio, data_fim) VALUES
(202001, 2020,  1, 'Janeiro',   1, 1, '2020-01-01', '2020-01-31'),
(202002, 2020,  2, 'Fevereiro', 1, 1, '2020-02-01', '2020-02-29'),
(202003, 2020,  3, 'Março',     1, 1, '2020-03-01', '2020-03-31'),
(202004, 2020,  4, 'Abril',     2, 1, '2020-04-01', '2020-04-30'),
(202005, 2020,  5, 'Maio',      2, 1, '2020-05-01', '2020-05-31'),
(202006, 2020,  6, 'Junho',     2, 1, '2020-06-01', '2020-06-30'),
(202007, 2020,  7, 'Julho',     3, 2, '2020-07-01', '2020-07-31'),
(202008, 2020,  8, 'Agosto',    3, 2, '2020-08-01', '2020-08-31'),
(202009, 2020,  9, 'Setembro',  3, 2, '2020-09-01', '2020-09-30'),
(202010, 2020, 10, 'Outubro',   4, 2, '2020-10-01', '2020-10-31'),
(202011, 2020, 11, 'Novembro',  4, 2, '2020-11-01', '2020-11-30'),
(202012, 2020, 12, 'Dezembro',  4, 2, '2020-12-01', '2020-12-31')
ON CONFLICT (id_periodo) DO NOTHING;
