-- Etapa 9 (E3 — Issue #28): Otimização de Performance da Camada de Consumo
-- Somente índices e estatísticas. A surrogate key persistida em periodo e
-- medicamento (CHAR(32) STORED) e as views dim_tempo/dim_medicamento fazem
-- parte do modelo e ficam em sql/11_dimensional_dim_municipio_scd.sql, que
-- precisa ter sido aplicado antes deste arquivo.
--
-- Idempotente: pode ser reaplicado (IF NOT EXISTS).
-- ATENÇÃO: CREATE INDEX (sem CONCURRENTLY) bloqueia escritas em
-- fato_venda_medicamento enquanto roda — não execute durante uma carga.
--
-- Este arquivo NÃO altera work_mem/jit. Um ALTER DATABASE valeria para todas
-- as conexões, inclusive a carga. Para o painel, configure na sessão ou no
-- papel do painel (ex.: ALTER ROLE painel SET work_mem = '256MB').

-- 1. Índices UNIQUE sobre as surrogate keys persistidas das dimensões.
-- As tabelas são pequenas (o planejador as lê com Seq Scan), mas a unicidade
-- comprovada permite ao otimizador marcar os Hash Joins como "Inner Unique".
CREATE UNIQUE INDEX IF NOT EXISTS idx_periodo_sk_tempo
    ON periodo (sk_tempo);

CREATE UNIQUE INDEX IF NOT EXISTS idx_medicamento_sk_medicamento
    ON medicamento (sk_medicamento);

-- 2. Evita estouro de /dev/shm (64 MB padrão no Docker) durante a construção
-- do índice na tabela fato. SET vale só para esta sessão.
SET max_parallel_maintenance_workers = 0;
SET maintenance_work_mem = '256MB';

-- 3. Índice B-Tree composto parcial com cobertura (INCLUDE) sobre as
-- surrogate keys usadas pelos joins da consulta crítica da E1.
-- O predicado parcial restringe o índice às dispensações de antimicrobianos
-- com idade informada; o INCLUDE carrega idade_paciente e quantidade_vendida,
-- permitindo Index Only Scan (Heap Fetches: 0 após VACUUM).
CREATE INDEX IF NOT EXISTS idx_fato_venda_antimicrobiano_covering
    ON fato_venda_medicamento (sk_municipio, sk_tempo, sk_medicamento)
    INCLUDE (idade_paciente, quantidade_vendida)
    WHERE eh_antimicrobiano = TRUE AND idade_paciente IS NOT NULL;

-- 4. Estatísticas do otimizador. O VACUUM (que atualiza o Visibility Map e
-- garante Heap Fetches: 0) não pode rodar dentro de transação/script
-- multi-comando; é executado à parte por `make otimizar-performance`.
ANALYZE periodo;
ANALYZE medicamento;
ANALYZE dim_municipio;
ANALYZE fato_venda_medicamento;
