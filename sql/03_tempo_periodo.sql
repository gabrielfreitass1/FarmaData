-- ============================================================================
-- Etapa 2: Tempo - Tabela de Períodos
-- Descrição: Estrutura e geração dos 12 meses do ano de recorte analítico (2020)
-- ============================================================================

CREATE TABLE IF NOT EXISTS periodo (
    id_periodo INT PRIMARY KEY, -- Formato numérico YYYYMM (ex: 202001)
    ano INT NOT NULL CHECK (ano >= 2000 AND ano <= 2100),
    mes INT NOT NULL CHECK (mes >= 1 AND mes <= 12),
    nome_mes VARCHAR(20) NOT NULL,
    trimestre INT NOT NULL CHECK (trimestre BETWEEN 1 AND 4),
    semestre INT NOT NULL CHECK (semestre BETWEEN 1 AND 2),
    data_inicio DATE NOT NULL,
    data_fim DATE NOT NULL,
    CONSTRAINT uq_periodo_ano_mes UNIQUE (ano, mes)
);

COMMENT ON TABLE periodo IS 'Dimensão de tempo mensal para agregação e particionamento temporal das vendas';
COMMENT ON COLUMN periodo.id_periodo IS 'Código identificador do período no formato YYYYMM';
COMMENT ON COLUMN periodo.ano IS 'Ano de referência da competência da venda';
COMMENT ON COLUMN periodo.mes IS 'Mês de referência (1 a 12)';
COMMENT ON COLUMN periodo.nome_mes IS 'Nome do mês por extenso em português';
COMMENT ON COLUMN periodo.data_inicio IS 'Primeiro dia do mês de referência';
COMMENT ON COLUMN periodo.data_fim IS 'Último dia do mês de referência';

-- Inserção determinística dos 12 meses do ano de recorte escolhido (2020)
INSERT INTO periodo (id_periodo, ano, mes, nome_mes, trimestre, semestre, data_inicio, data_fim) VALUES
(202001, 2020, 1, 'Janeiro',   1, 1, '2020-01-01', '2020-01-31'),
(202002, 2020, 2, 'Fevereiro', 1, 1, '2020-02-01', '2020-02-29'), -- Ano bissexto
(202003, 2020, 3, 'Março',     1, 1, '2020-03-01', '2020-03-31'),
(202004, 2020, 4, 'Abril',     2, 1, '2020-04-01', '2020-04-30'),
(202005, 2020, 5, 'Maio',      2, 1, '2020-05-01', '2020-05-31'),
(202006, 2020, 6, 'Junho',     2, 1, '2020-06-01', '2020-06-30'),
(202007, 2020, 7, 'Julho',     3, 2, '2020-07-01', '2020-07-31'),
(202008, 2020, 8, 'Agosto',    3, 2, '2020-08-01', '2020-08-31'),
(202009, 2020, 9, 'Setembro',  3, 2, '2020-09-01', '2020-09-30'),
(202010, 2020, 10, 'Outubro',  4, 2, '2020-10-01', '2020-10-31'),
(202011, 2020, 11, 'Novembro', 4, 2, '2020-11-01', '2020-11-30'),
(202012, 2020, 12, 'Dezembro', 4, 2, '2020-12-01', '2020-12-31')
ON CONFLICT (id_periodo) DO NOTHING;
