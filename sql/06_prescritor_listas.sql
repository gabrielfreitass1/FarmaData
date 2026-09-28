-- Etapa 4: Conselho profissional e listas de valores fixos do dicionário Anvisa

-- 4.1 Conselho Profissional
CREATE TABLE IF NOT EXISTS conselho_profissional (
    id_conselho SMALLINT    PRIMARY KEY,
    sigla       VARCHAR(10) NOT NULL UNIQUE,
    descricao   VARCHAR(80) NOT NULL
);

COMMENT ON TABLE conselho_profissional IS 'Conselhos de fiscalização profissional que autorizam prescrição';

INSERT INTO conselho_profissional (id_conselho, sigla, descricao) VALUES
(1, 'CRM',    'Conselho Regional de Medicina'),
(2, 'CRO',    'Conselho Regional de Odontologia'),
(3, 'CRMV',   'Conselho Regional de Medicina Veterinária'),
(4, 'CRF',    'Conselho Regional de Farmácia'),
(5, 'COREN',  'Conselho Regional de Enfermagem'),
(6, 'CRN',    'Conselho Regional de Nutrição'),
(7, 'CREFITO','Conselho Regional de Fisioterapia e Terapia Ocupacional'),
(8, 'CRP',    'Conselho Regional de Psicologia')
ON CONFLICT (id_conselho) DO NOTHING;

-- 4.2 Tipo de Receituário (5 opções do SNGPC/Anvisa)
CREATE TABLE IF NOT EXISTS tipo_receituario (
    id_tipo_receituario SMALLINT    PRIMARY KEY,
    codigo              VARCHAR(5)  NOT NULL UNIQUE,
    descricao           VARCHAR(100) NOT NULL
);

COMMENT ON TABLE tipo_receituario IS 'Tipos de receituário definidos pela Anvisa para dispensação de controlados';

INSERT INTO tipo_receituario (id_tipo_receituario, codigo, descricao) VALUES
(1, 'A',  'Notificação de Receita A — entorpecentes e psicotrópicos'),
(2, 'B1', 'Notificação de Receita B Azul — psicotrópicos'),
(3, 'B2', 'Notificação de Receita B2 Amarela — antidepressivos e ansiolíticos'),
(4, 'C1', 'Receita de Controle Especial — outras substâncias'),
(5, 'D',  'Receita Veterinária de Controle Especial')
ON CONFLICT (id_tipo_receituario) DO NOTHING;

-- 4.3 Unidade de Medida
CREATE TABLE IF NOT EXISTS unidade_medida (
    id_unidade_medida SMALLINT    PRIMARY KEY,
    descricao         VARCHAR(30) NOT NULL UNIQUE
);

COMMENT ON TABLE unidade_medida IS 'Unidades de medida da quantidade dispensada (dicionário Anvisa/SNGPC)';

INSERT INTO unidade_medida (id_unidade_medida, descricao) VALUES
(1, 'Caixa'),
(2, 'Frasco'),
(3, 'Ampola'),
(4, 'Bisnaga'),
(5, 'Envelope'),
(6, 'Tubo')
ON CONFLICT (id_unidade_medida) DO NOTHING;

-- 4.4 Unidade de Idade (somente para antimicrobianos)
CREATE TABLE IF NOT EXISTS unidade_idade (
    id_unidade_idade SMALLINT    PRIMARY KEY,
    descricao        VARCHAR(20) NOT NULL UNIQUE
);

COMMENT ON TABLE unidade_idade IS 'Unidade de expressão da idade do paciente (somente antimicrobianos)';

INSERT INTO unidade_idade (id_unidade_idade, descricao) VALUES
(1, 'Anos'),
(2, 'Meses')
ON CONFLICT (id_unidade_idade) DO NOTHING;
