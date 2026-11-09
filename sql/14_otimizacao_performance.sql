-- Etapa 9 (E3 — Issue #28): Otimização de Performance da Camada de Consumo
-- Aplica exclusivamente as intervenções estruturais e de sessão comprovadas no
-- estudo de ablação sobre a query crítica da E1 no esquema estrela
-- (fato_venda_medicamento + dim_tempo + dim_municipio + dim_medicamento),
-- mantendo a consulta SQL 100% idêntica antes e depois (joins via sk_tempo,
-- sk_municipio e sk_medicamento).

-- 1. Marca sk_hash() como PARALLEL SAFE.
-- Por padrão no PostgreSQL, funções SQL sem marcação explícita são PARALLEL UNSAFE,
-- o que impedia o planejador de considerar planos paralelos em qualquer consulta
-- envolvendo as views dimensionais (sql/11_dimensional_dim_municipio_scd.sql).
ALTER FUNCTION sk_hash(TEXT, ANYELEMENT) PARALLEL SAFE;

-- 2. Materialização e tipagem estrita CHAR(32) das surrogate keys nas dimensões
-- conformadas (periodo e medicamento) — resolve a dívida técnica registrada no
-- ADR-004 (seção 5: "As dimensões conformadas (views) não têm sk_* persistida").
--
-- Problema original: em fato_venda_medicamento, sk_tempo e sk_medicamento são
-- CHAR(32) (bpchar), mas nas views dim_tempo e dim_medicamento eram calculadas
-- em tempo de execução via sk_hash() retornando TEXT. Isso forçava o cast
-- (f.sk_tempo)::text e (f.sk_medicamento)::text em todas as 4,59M linhas,
-- impedia o uso de estatísticas (erro de cardinalidade de 31x: 67.808 estimadas
-- vs. 2.122.690 reais) e induzia um Sort externo (245 MB em disco) + Merge Join.
DROP VIEW IF EXISTS dim_tempo;
DROP VIEW IF EXISTS dim_medicamento;

ALTER TABLE periodo DROP COLUMN IF EXISTS sk_tempo;
ALTER TABLE periodo
    ADD COLUMN sk_tempo CHAR(32)
    GENERATED ALWAYS AS (sk_hash('tempo', id_periodo)::char(32)) STORED;

CREATE UNIQUE INDEX IF NOT EXISTS idx_periodo_sk_tempo
    ON periodo (sk_tempo);

ALTER TABLE medicamento DROP COLUMN IF EXISTS sk_medicamento;
ALTER TABLE medicamento
    ADD COLUMN sk_medicamento CHAR(32)
    GENERATED ALWAYS AS (sk_hash('medicamento', id_medicamento)::char(32)) STORED;

CREATE UNIQUE INDEX IF NOT EXISTS idx_medicamento_sk_medicamento
    ON medicamento (sk_medicamento);

CREATE OR REPLACE VIEW dim_tempo AS
SELECT
    sk_tempo,
    id_periodo,
    ano,
    mes,
    nome_mes,
    trimestre,
    semestre,
    data_inicio,
    data_fim
FROM periodo;

CREATE OR REPLACE VIEW dim_medicamento AS
SELECT
    sk_medicamento,
    id_medicamento,
    principio_ativo,
    descricao_apresentacao
FROM medicamento;

-- 3. Evita estouro de /dev/shm (64 MB padrão no Docker) durante a construção
-- do índice composto na tabela fato.
SET max_parallel_maintenance_workers = 0;
SET maintenance_work_mem = '256MB';

-- 4. Índice B-Tree Composto Parcial com Cobertura (Covering Index / INCLUDE)
-- na fato_venda_medicamento exatamente sobre as surrogate keys originais da
-- consulta (sk_municipio, sk_tempo, sk_medicamento).
-- Filtra nativamente o subconjunto de antimicrobianos com idade informada e
-- inclui no payload das folhas (INCLUDE) idade_paciente e quantidade_vendida,
-- permitindo responder à consulta via Index Only Scan com Heap Fetches: 0
-- (reduzindo os blocos compartilhados acessados de 161.832 para 42.751).
CREATE INDEX IF NOT EXISTS idx_fato_venda_antimicrobiano_covering
    ON fato_venda_medicamento (sk_municipio, sk_tempo, sk_medicamento)
    INCLUDE (idade_paciente, quantidade_vendida)
    WHERE eh_antimicrobiano = TRUE AND idade_paciente IS NOT NULL;

-- 5. Ajuste de parâmetros analíticos no nível do banco atual:
-- - work_mem = '256MB': permite que o HashAggregate processe os 216.358 grupos
--   em um único lote em RAM (Batches: 1, Memory Usage: 131089kB), eliminando
--   100% do spill to disk (temp read=0, written=0).
-- - jit = 'off': elimina o overhead de compilação LLVM em varreduras indexadas.
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET work_mem = ''256MB''', current_database());
    EXECUTE format('ALTER DATABASE %I SET jit = ''off''', current_database());
END $$;

-- 6. Atualiza estatísticas do otimizador nas tabelas base e fato.
ANALYZE periodo;
ANALYZE medicamento;
ANALYZE dim_municipio;
ANALYZE fato_venda_medicamento;
