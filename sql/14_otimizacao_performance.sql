-- Etapa 9 (E3 — Issue #28): Otimização de Performance da Camada de Consumo
-- Aplica ajustes de função, índices (B-Tree Covering parcial, B-Tree funcional
-- e BRIN temporal) e parâmetros analíticos para acelerar as consultas do
-- painel de gestão sobre o esquema estrela (fato_venda_medicamento + dimensões).

-- 1. Permite que o otimizador utilize planos paralelos (Parallel Seq Scan,
-- Parallel Hash Join, Parallel Index Only Scan) ao consultar as views
-- dimensionais que invocam sk_hash(). Por padrão, funções SQL sem marcação
-- explícita são PARALLEL UNSAFE no PostgreSQL.
ALTER FUNCTION sk_hash(TEXT, ANYELEMENT) PARALLEL SAFE;

-- 2. Evita estouro de /dev/shm (64 MB padrão no Docker) durante a criação de
-- índices pesados na tabela fato.
SET max_parallel_maintenance_workers = 0;
SET maintenance_work_mem = '256MB';

-- 3. Índices funcionais nas tabelas base das views dimensionais (dim_tempo e
-- dim_medicamento). Além de permitirem Index Scan por surrogate key, fazem o
-- ANALYZE coletar estatísticas (pg_stats) sobre a expressão sk_hash(),
-- corrigindo o erro de estimativa de cardinalidade nos joins.
CREATE UNIQUE INDEX IF NOT EXISTS idx_periodo_sk_tempo_bpchar
    ON periodo ((sk_hash('tempo', id_periodo)::char(32)));

CREATE UNIQUE INDEX IF NOT EXISTS idx_periodo_sk_tempo_text
    ON periodo (sk_hash('tempo', id_periodo));

CREATE UNIQUE INDEX IF NOT EXISTS idx_medicamento_sk_med_bpchar
    ON medicamento ((sk_hash('medicamento', id_medicamento)::char(32)));

CREATE UNIQUE INDEX IF NOT EXISTS idx_medicamento_sk_med_text
    ON medicamento (sk_hash('medicamento', id_medicamento));

-- 4. Índice composto de cobertura (Covering Index) em dim_municipio para
-- filtros regionais/estaduais sem acesso à heap.
CREATE INDEX IF NOT EXISTS idx_dim_municipio_regiao_sk
    ON dim_municipio (regiao, sk_municipio)
    INCLUDE (sigla_uf, nome_municipio);

-- 5. Índice BRIN (Block Range Index) temporal em fato_venda_medicamento.
-- Como a carga insere os dados cronologicamente por arquivo mensal, o BRIN
-- ocupa menos de 200 KB e permite poda de blocos (block skipping) em recortes
-- por data_venda e id_periodo.
CREATE INDEX IF NOT EXISTS idx_fato_venda_periodo_brin
    ON fato_venda_medicamento USING brin (data_venda, id_periodo)
    WITH (pages_per_range = 32);

-- 6. Índice B-Tree Composto Parcial com Cobertura (INCLUDE) na
-- fato_venda_medicamento para a consulta crítica da pergunta de gestão da E1
-- (distribuição por município/região, período, princípio ativo e faixa etária).
-- Elimina 100% dos acessos à heap de 1,26 GB (Index Only Scan com Heap Fetches: 0).
CREATE INDEX IF NOT EXISTS idx_fato_venda_antimicrobiano_covering
    ON fato_venda_medicamento (sk_municipio, id_periodo, id_medicamento)
    INCLUDE (idade_paciente, quantidade_vendida)
    WHERE eh_antimicrobiano = TRUE AND idade_paciente IS NOT NULL;

-- 7. Ajuste de parâmetros analíticos no nível do banco atual (elimina spill to
-- disk em agregações HashAggregate multidimensionais e overhead de compilação JIT).
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET work_mem = ''256MB''', current_database());
    EXECUTE format('ALTER DATABASE %I SET jit = ''off''', current_database());
END $$;

-- 8. Atualiza estatísticas do otimizador.
ANALYZE periodo;
ANALYZE medicamento;
ANALYZE dim_municipio;
ANALYZE fato_venda_medicamento;
