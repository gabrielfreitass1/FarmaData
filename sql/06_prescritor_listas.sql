-- ============================================================================
-- Etapa 4: Prescritor e Listas de Valores Fixos
-- Descrição: Tabela de conselhos profissionais e domínios fixos do dicionário Anvisa
--            (tipo de receituário, unidade de medida e unidade de idade)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 4.1  Conselho Profissional (quem emitiu a prescrição)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS conselho_profissional (
    id_conselho  SMALLINT PRIMARY KEY,
    sigla        VARCHAR(10) NOT NULL UNIQUE,
    descricao    VARCHAR(80) NOT NULL
);

COMMENT ON TABLE conselho_profissional IS 'Conselhos federais de fiscalização do exercício profissional que autorizam prescrição';
COMMENT ON COLUMN conselho_profissional.id_conselho IS 'Identificador sintético do conselho';
COMMENT ON COLUMN conselho_profissional.sigla IS 'Sigla do conselho (ex: CRM, CRO, CRMV)';
COMMENT ON COLUMN conselho_profissional.descricao IS 'Nome completo do conselho profissional';

INSERT INTO conselho_profissional (id_conselho, sigla, descricao) VALUES
(1,  'CRM',   'Conselho Regional de Medicina'),
(2,  'CRO',   'Conselho Regional de Odontologia'),
(3,  'CRMV',  'Conselho Regional de Medicina Veterinária'),
(4,  'CRF',   'Conselho Regional de Farmácia'),
(5,  'COREN', 'Conselho Regional de Enfermagem'),
(6,  'CRN',   'Conselho Regional de Nutrição'),
(7,  'CREFITO','Conselho Regional de Fisioterapia e Terapia Ocupacional'),
(8,  'CRP',   'Conselho Regional de Psicologia')
ON CONFLICT (id_conselho) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 4.2  Tipo de Receituário (5 opções fixas do dicionário Anvisa / SNGPC)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tipo_receituario (
    id_tipo_receituario SMALLINT PRIMARY KEY,
    codigo              VARCHAR(5)  NOT NULL UNIQUE,
    descricao           VARCHAR(100) NOT NULL
);

COMMENT ON TABLE tipo_receituario IS 'Tipos de receituário definidos pela Anvisa para dispensação de medicamentos controlados';
COMMENT ON COLUMN tipo_receituario.codigo IS 'Código alfanumérico do tipo conforme SNGPC (ex: B1, C1)';
COMMENT ON COLUMN tipo_receituario.descricao IS 'Descrição do tipo de receituário conforme regulamentação';

INSERT INTO tipo_receituario (id_tipo_receituario, codigo, descricao) VALUES
(1, 'A',  'Receita de Controle Especial em 2 vias (Notificação de Receita A — psicotrópicos e entorpecentes)'),
(2, 'B1', 'Notificação de Receita B (Azul) — psicotrópicos sujeitos a controle especial'),
(3, 'B2', 'Notificação de Receita B2 (Amarela) — antidepressivos e ansiolíticos de uso prolongado'),
(4, 'C1', 'Receita de Controle Especial — outras substâncias sujeitas a controle especial'),
(5, 'D',  'Receita Veterinária de Controle Especial')
ON CONFLICT (id_tipo_receituario) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 4.3  Unidade de Medida da Quantidade Vendida
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS unidade_medida (
    id_unidade_medida SMALLINT PRIMARY KEY,
    descricao         VARCHAR(30) NOT NULL UNIQUE
);

COMMENT ON TABLE unidade_medida IS 'Unidades de medida da quantidade dispensada, conforme dicionário Anvisa/SNGPC';

INSERT INTO unidade_medida (id_unidade_medida, descricao) VALUES
(1, 'Caixa'),
(2, 'Frasco'),
(3, 'Ampola'),
(4, 'Bisnaga'),
(5, 'Envelope'),
(6, 'Tubo')
ON CONFLICT (id_unidade_medida) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 4.4  Unidade de Idade do Paciente (anos / meses — para antimicrobianos)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS unidade_idade (
    id_unidade_idade SMALLINT PRIMARY KEY,
    descricao        VARCHAR(20) NOT NULL UNIQUE
);

COMMENT ON TABLE unidade_idade IS 'Unidade de expressão da idade do paciente (somente para antimicrobianos)';

INSERT INTO unidade_idade (id_unidade_idade, descricao) VALUES
(1, 'Anos'),
(2, 'Meses')
ON CONFLICT (id_unidade_idade) DO NOTHING;
