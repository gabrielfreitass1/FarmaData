\set ON_ERROR_STOP on

-- Cobertura genérica de todas as PKs: nullabilidade e unicidade (inclui chaves compostas).
DO $$
DECLARE n integer;
BEGIN
  -- PK/UNIQUE/FK são garantidas pelo próprio PostgreSQL. Conferimos que os
  -- constraints e índices existem/estão válidos sem agrupar dezenas de milhões de PKs.
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE connamespace=current_schema()::regnamespace
             AND contype IN ('p','f') AND NOT convalidated)
  THEN RAISE EXCEPTION 'Há chave primária ou estrangeira não validada'; END IF;
  IF EXISTS (
      SELECT 1 FROM pg_constraint c JOIN pg_index i ON i.indexrelid=c.conindid
      WHERE c.connamespace=current_schema()::regnamespace AND c.contype='p'
        AND (NOT i.indisvalid OR NOT i.indisunique)
  ) THEN RAISE EXCEPTION 'Há índice de chave primária inválido ou não único'; END IF;
  IF EXISTS (
      SELECT 1 FROM pg_constraint c
      CROSS JOIN LATERAL unnest(c.conkey) k(attnum)
      JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
      WHERE c.connamespace=current_schema()::regnamespace AND c.contype='p' AND NOT a.attnotnull
  ) THEN RAISE EXCEPTION 'Há coluna de chave primária sem NOT NULL'; END IF;

  IF EXISTS (SELECT 1 FROM unidade_federativa WHERE regiao NOT IN ('Norte','Nordeste','Centro-Oeste','Sudeste','Sul'))
  THEN RAISE EXCEPTION 'Região fora do domínio em unidade_federativa'; END IF;
  IF EXISTS (SELECT 1 FROM tipo_receituario WHERE codigo NOT IN ('A','B1','B2','C1','D'))
  THEN RAISE EXCEPTION 'Código de receituário fora do domínio'; END IF;
  IF EXISTS (SELECT 1 FROM unidade_idade WHERE descricao NOT IN ('Anos','Meses'))
  THEN RAISE EXCEPTION 'Unidade de idade fora do domínio'; END IF;
  IF EXISTS (SELECT 1 FROM periodo WHERE mes NOT BETWEEN 1 AND 12 OR trimestre NOT BETWEEN 1 AND 4
      OR semestre NOT BETWEEN 1 AND 2 OR id_periodo<>ano*100+mes OR data_fim<data_inicio OR data_fim>CURRENT_DATE)
  THEN RAISE EXCEPTION 'Período contém valor inválido ou data futura'; END IF;
  IF EXISTS (SELECT 1 FROM ibge_populacao_municipio WHERE populacao<0 OR ano>EXTRACT(YEAR FROM CURRENT_DATE))
     OR EXISTS (SELECT 1 FROM ibge_populacao_faixa_etaria_municipio WHERE populacao<0 OR ano>EXTRACT(YEAR FROM CURRENT_DATE))
  THEN RAISE EXCEPTION 'População IBGE negativa ou em ano futuro'; END IF;
  IF EXISTS (SELECT 1 FROM clima_mensal_uf WHERE precipitacao_media_mm<0 OR qtd_estacoes<0)
  THEN RAISE EXCEPTION 'Clima contém precipitação ou número de estações negativo'; END IF;

  -- Surrogate keys calculadas nas dimensões-view não aparecem no catálogo de PKs.
  IF EXISTS (SELECT 1 FROM dim_tempo WHERE sk_tempo IS NULL)
     OR EXISTS (SELECT sk_tempo FROM dim_tempo GROUP BY sk_tempo HAVING count(*)>1)
  THEN RAISE EXCEPTION 'sk_tempo nula ou duplicada'; END IF;
  IF EXISTS (SELECT 1 FROM dim_medicamento WHERE sk_medicamento IS NULL)
     OR EXISTS (SELECT sk_medicamento FROM dim_medicamento GROUP BY sk_medicamento HAVING count(*)>1)
  THEN RAISE EXCEPTION 'sk_medicamento nula ou duplicada'; END IF;
  IF EXISTS (SELECT 1 FROM dim_conselho WHERE sk_conselho IS NULL)
     OR EXISTS (SELECT sk_conselho FROM dim_conselho GROUP BY sk_conselho HAVING count(*)>1)
  THEN RAISE EXCEPTION 'sk_conselho nula ou duplicada'; END IF;
  IF EXISTS (SELECT 1 FROM dim_tipo_receituario WHERE sk_tipo_receituario IS NULL)
     OR EXISTS (SELECT sk_tipo_receituario FROM dim_tipo_receituario GROUP BY sk_tipo_receituario HAVING count(*)>1)
  THEN RAISE EXCEPTION 'sk_tipo_receituario nula ou duplicada'; END IF;
  IF EXISTS (SELECT 1 FROM dim_unidade_medida WHERE sk_unidade_medida IS NULL)
     OR EXISTS (SELECT sk_unidade_medida FROM dim_unidade_medida GROUP BY sk_unidade_medida HAVING count(*)>1)
  THEN RAISE EXCEPTION 'sk_unidade_medida nula ou duplicada'; END IF;

  RAISE NOTICE 'Constraints de chave, dimensões e domínios estáticos: OK';
END $$;

-- Agrega a origem e a fato uma vez; as mesmas métricas alimentam volume,
-- regras de linha e série temporal, evitando várias varreduras completas.
CREATE TEMP TABLE _qualidade_origem_mensal AS
SELECT p.id_periodo, count(v.id_venda)::bigint AS vendas,
       coalesce(bool_or(v.quantidade_vendida<=0 OR v.idade_paciente<0
         OR (v.sexo_paciente IS NOT NULL AND v.sexo_paciente NOT IN ('M','F'))
         OR v.data_venda>CURRENT_DATE
         OR v.data_venda NOT BETWEEN p.data_inicio AND p.data_fim
         OR (NOT v.eh_antimicrobiano AND (v.codigo_cid10 IS NOT NULL OR v.sexo_paciente IS NOT NULL OR v.idade_paciente IS NOT NULL)))
         FILTER (WHERE v.id_venda IS NOT NULL),false) AS dominio_invalido
FROM periodo p LEFT JOIN venda_medicamento v USING(id_periodo)
GROUP BY p.id_periodo;

CREATE TEMP TABLE _qualidade_fato_mensal AS
SELECT f.id_periodo,count(*)::bigint AS vendas,
       coalesce(bool_or(f.quantidade_vendida<=0 OR f.idade_paciente<0
         OR (f.sexo_paciente IS NOT NULL AND f.sexo_paciente NOT IN ('M','F'))
         OR f.data_venda>CURRENT_DATE
         OR p.id_periodo IS NULL OR f.data_venda NOT BETWEEN p.data_inicio AND p.data_fim
         OR (NOT f.eh_antimicrobiano AND (f.codigo_cid10 IS NOT NULL OR f.sexo_paciente IS NOT NULL OR f.idade_paciente IS NOT NULL))),false) AS dominio_invalido,
       coalesce(bool_or(f.sk_tempo::text<>sk_hash('tempo',f.id_periodo)
         OR f.sk_medicamento::text<>sk_hash('medicamento',f.id_medicamento)
         OR (f.id_conselho IS NULL)<>(f.sk_conselho IS NULL)
         OR (f.id_conselho IS NOT NULL AND f.sk_conselho::text<>sk_hash('conselho',f.id_conselho))
         OR (f.id_tipo_receituario IS NULL)<>(f.sk_tipo_receituario IS NULL)
         OR (f.id_tipo_receituario IS NOT NULL AND f.sk_tipo_receituario::text<>sk_hash('tipo_receituario',f.id_tipo_receituario))
         OR (f.id_unidade_medida IS NULL)<>(f.sk_unidade_medida IS NULL)
         OR (f.id_unidade_medida IS NOT NULL AND f.sk_unidade_medida::text<>sk_hash('unidade_medida',f.id_unidade_medida))),false) AS sk_invalida
FROM fato_venda_medicamento f LEFT JOIN periodo p ON p.id_periodo=f.id_periodo GROUP BY f.id_periodo;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM _qualidade_origem_mensal WHERE dominio_invalido)
  THEN RAISE EXCEPTION 'venda_medicamento viola domínio de quantidade, idade, sexo, data ou antimicrobiano'; END IF;
  IF EXISTS (SELECT 1 FROM _qualidade_fato_mensal WHERE dominio_invalido)
  THEN RAISE EXCEPTION 'fato_venda_medicamento viola regra de domínio'; END IF;
  IF EXISTS (SELECT 1 FROM _qualidade_fato_mensal WHERE sk_invalida)
  THEN RAISE EXCEPTION 'fato possui chave substituta inválida para sua chave natural'; END IF;
  IF EXISTS (SELECT 1 FROM _qualidade_fato_mensal f LEFT JOIN dim_tempo d ON d.id_periodo=f.id_periodo WHERE d.id_periodo IS NULL)
  THEN RAISE EXCEPTION 'fato possui id_periodo sem dimensão de tempo'; END IF;
  RAISE NOTICE 'Domínios de venda/fato e relacionamentos das chaves substitutas: OK';
END $$;

-- O limite padrão representa uma carga anual homologada; o CI passa 12 para fixture reduzida.
SELECT coalesce(sum(vendas),0) AS volume_vendas FROM _qualidade_origem_mensal \gset
\if :{?min_vendas}
\else
  \set min_vendas 1000000
\endif
\echo Volume mínimo: :volume_vendas / :min_vendas
SELECT 1 / CASE WHEN :volume_vendas::bigint >= :min_vendas::bigint THEN 1 ELSE 0 END;

-- Detector reutilizado pela série real e pelo teste negativo, temporário à sessão do psql.
CREATE TEMP TABLE _qualidade_bootstrap (x integer);
CREATE OR REPLACE FUNCTION pg_temp.anomalias_mensais(
  p_periodos integer[], p_volumes numeric[], p_limite_relativo numeric DEFAULT 0.40
)
RETURNS TABLE(id_periodo integer, volume numeric, mediana numeric, desvio_relativo numeric)
LANGUAGE sql IMMUTABLE AS $$
  WITH serie AS (
    SELECT s.id_periodo, s.volume
    FROM unnest(p_periodos, p_volumes) AS s(id_periodo, volume)
  ), referencia AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY volume::double precision)::numeric AS mediana
    FROM serie
  )
  SELECT s.id_periodo, s.volume, r.mediana,
         abs(s.volume-r.mediana)/NULLIF(r.mediana,0) AS desvio_relativo
  FROM serie s CROSS JOIN referencia r
  WHERE r.mediana > 0
    AND abs(s.volume-r.mediana)/NULLIF(r.mediana,0) >= p_limite_relativo
$$;

-- Anomalia silenciosa: detecta variações de pelo menos 40% contra a mediana mensal.
DO $$
DECLARE n_meses integer; periodos integer[]; volumes numeric[]; outliers text;
BEGIN
  SELECT count(*),array_agg(id_periodo ORDER BY id_periodo),array_agg(vendas::numeric ORDER BY id_periodo)
    INTO n_meses,periodos,volumes FROM _qualidade_origem_mensal;
  IF n_meses<6 THEN RAISE EXCEPTION 'Série histórica insuficiente: % meses; mínimo 6',n_meses; END IF;
  SELECT string_agg(id_periodo||' (volume='||volume||', variação='||round(desvio_relativo*100,1)||'%)',', ' ORDER BY id_periodo)
    INTO outliers FROM pg_temp.anomalias_mensais(periodos,volumes,0.40);
  IF outliers IS NOT NULL THEN RAISE EXCEPTION 'Anomalia mensal (desvio relativo >= 40%% da mediana): %',outliers; END IF;
  RAISE NOTICE 'Distribuição mensal: OK (% meses; nenhum desvio relativo >= 40%% da mediana)',n_meses;
END $$;

-- Teste negativo: injeta uma queda de 50% e exige que o mesmo detector a sinalize.
DO $$
DECLARE detectadas integer; periodo_anomalo integer;
BEGIN
  SELECT count(*),min(id_periodo) INTO detectadas,periodo_anomalo
  FROM pg_temp.anomalias_mensais(
    ARRAY[202001,202002,202003,202004,202005,202006,202007,202008,202009,202010,202011,202012],
    ARRAY[97,98,99,100,50,101,102,103,104,105,106,107]::numeric[],
    0.40
  );
  IF detectadas<>1 OR periodo_anomalo<>202005
  THEN RAISE EXCEPTION 'Teste negativo falhou: esperada detecção da queda de 50%% em 202005; encontradas % anomalia(s)',detectadas; END IF;
  RAISE NOTICE 'Teste negativo: queda de 50%% detectada em 202005 pelo mesmo detector da série real';
END $$;

DO $$
DECLARE origem bigint; fato bigint;
BEGIN
  SELECT coalesce(sum(vendas),0) INTO origem FROM _qualidade_origem_mensal;
  SELECT coalesce(sum(vendas),0) INTO fato FROM _qualidade_fato_mensal;
  IF origem>0 AND origem<>fato THEN RAISE EXCEPTION 'Contagem origem/fato divergente: % / %',origem,fato; END IF;
  RAISE NOTICE 'Origem/fato dimensional: OK (% / %)',origem,fato;
END $$;
