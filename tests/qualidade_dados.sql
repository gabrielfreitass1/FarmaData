\set ON_ERROR_STOP on

-- Cobertura genérica de todas as PKs: nullabilidade e unicidade (inclui chaves compostas).
DO $$
DECLARE r record; n bigint;
BEGIN
  FOR r IN
    SELECT c.conrelid::regclass rel, c.conname,
      string_agg(format('%I',a.attname),', ' ORDER BY k.ord) cols,
      string_agg(format('t.%I IS NULL',a.attname),' OR ' ORDER BY k.ord) nulls
    FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum,ord)
    JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
    WHERE c.contype='p' AND c.connamespace=current_schema()::regnamespace
    GROUP BY c.conrelid,c.conname
  LOOP
    EXECUTE format('SELECT count(*) FROM %s t WHERE %s',r.rel,r.nulls) INTO n;
    IF n>0 THEN RAISE EXCEPTION 'PK % em % contém % chave(s) nula(s)',r.conname,r.rel,n; END IF;
    EXECUTE format('SELECT count(*) FROM (SELECT %s FROM %s GROUP BY %s HAVING count(*)>1) d',r.cols,r.rel,r.cols) INTO n;
    IF n>0 THEN RAISE EXCEPTION 'PK % em % contém duplicidade',r.conname,r.rel; END IF;
  END LOOP;

  -- Integridade referencial de todas as FKs declaradas, inclusive compostas.
  FOR r IN SELECT conrelid,confrelid,conname,conkey,confkey FROM pg_constraint
           WHERE contype='f' AND connamespace=current_schema()::regnamespace
  LOOP
    DECLARE join_sql text; nonnull_sql text;
    BEGIN
      SELECT string_agg(format('c.%I=p.%I',ca.attname,pa.attname),' AND ' ORDER BY ck.ord),
             string_agg(format('c.%I IS NOT NULL',ca.attname),' AND ' ORDER BY ck.ord)
        INTO join_sql,nonnull_sql
      FROM unnest(r.conkey) WITH ORDINALITY ck(attnum,ord)
      JOIN unnest(r.confkey) WITH ORDINALITY pk(attnum,ord) USING(ord)
      JOIN pg_attribute ca ON ca.attrelid=r.conrelid AND ca.attnum=ck.attnum
      JOIN pg_attribute pa ON pa.attrelid=r.confrelid AND pa.attnum=pk.attnum;
      EXECUTE format('SELECT count(*) FROM %s c WHERE (%s) AND NOT EXISTS (SELECT 1 FROM %s p WHERE %s)',
        r.conrelid::regclass,nonnull_sql,r.confrelid::regclass,join_sql) INTO n;
      IF n>0 THEN RAISE EXCEPTION 'FK % em % possui % registro(s) órfão(s)',r.conname,r.conrelid::regclass,n; END IF;
    END;
  END LOOP;

  IF EXISTS (SELECT 1 FROM venda_medicamento WHERE quantidade_vendida<=0 OR idade_paciente<0
      OR (sexo_paciente IS NOT NULL AND sexo_paciente NOT IN ('M','F')) OR data_venda>CURRENT_DATE
      OR (NOT eh_antimicrobiano AND (codigo_cid10 IS NOT NULL OR sexo_paciente IS NOT NULL OR idade_paciente IS NOT NULL)))
  THEN RAISE EXCEPTION 'venda_medicamento viola domínio de quantidade, idade, sexo, data ou antimicrobiano'; END IF;
  IF EXISTS (SELECT 1 FROM fato_venda_medicamento WHERE quantidade_vendida<=0 OR idade_paciente<0
      OR (sexo_paciente IS NOT NULL AND sexo_paciente NOT IN ('M','F')) OR data_venda>CURRENT_DATE
      OR (NOT eh_antimicrobiano AND (codigo_cid10 IS NOT NULL OR sexo_paciente IS NOT NULL OR idade_paciente IS NOT NULL)))
  THEN RAISE EXCEPTION 'fato_venda_medicamento viola regra de domínio'; END IF;
  IF EXISTS (SELECT 1 FROM unidade_federativa WHERE regiao NOT IN ('Norte','Nordeste','Centro-Oeste','Sudeste','Sul'))
  THEN RAISE EXCEPTION 'Região fora do domínio em unidade_federativa'; END IF;
  IF EXISTS (SELECT 1 FROM tipo_receituario WHERE codigo NOT IN ('A','B1','B2','C1','D'))
  THEN RAISE EXCEPTION 'Código de receituário fora do domínio'; END IF;
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

  -- As FKs para dimensões implementadas como views são verificadas por suas SKs hash.
  IF EXISTS (SELECT 1 FROM fato_venda_medicamento f WHERE f.sk_tempo IS NULL OR NOT EXISTS
      (SELECT 1 FROM dim_tempo d WHERE d.sk_tempo=f.sk_tempo))
  THEN RAISE EXCEPTION 'fato possui sk_tempo nula ou sem dimensão'; END IF;
  IF EXISTS (SELECT 1 FROM fato_venda_medicamento f WHERE f.sk_medicamento IS NULL OR NOT EXISTS
      (SELECT 1 FROM dim_medicamento d WHERE d.sk_medicamento=f.sk_medicamento))
  THEN RAISE EXCEPTION 'fato possui sk_medicamento nula ou sem dimensão'; END IF;
  IF EXISTS (SELECT 1 FROM fato_venda_medicamento f WHERE f.sk_conselho IS NOT NULL AND NOT EXISTS
      (SELECT 1 FROM dim_conselho d WHERE d.sk_conselho=f.sk_conselho))
     OR EXISTS (SELECT 1 FROM fato_venda_medicamento f WHERE f.sk_tipo_receituario IS NOT NULL AND NOT EXISTS
      (SELECT 1 FROM dim_tipo_receituario d WHERE d.sk_tipo_receituario=f.sk_tipo_receituario))
     OR EXISTS (SELECT 1 FROM fato_venda_medicamento f WHERE f.sk_unidade_medida IS NOT NULL AND NOT EXISTS
      (SELECT 1 FROM dim_unidade_medida d WHERE d.sk_unidade_medida=f.sk_unidade_medida))
  THEN RAISE EXCEPTION 'fato possui chave substituta sem dimensão correspondente'; END IF;
  RAISE NOTICE 'PKs, FKs e domínios: OK';
END $$;

-- O limite padrão representa uma carga anual homologada; o CI passa 12 para fixture reduzida.
SELECT count(*) AS volume_vendas FROM venda_medicamento \gset
\if :{?min_vendas}
\else
  \set min_vendas 1000000
\endif
\echo Volume mínimo: :volume_vendas / :min_vendas
SELECT 1 / CASE WHEN :volume_vendas::bigint >= :min_vendas::bigint THEN 1 ELSE 0 END;

-- Anomalia silenciosa: volume mensal nacional com z-score populacional acima de 3.
DO $$
DECLARE n_meses integer; outliers text;
BEGIN
  WITH mensal AS (
         SELECT p.id_periodo,count(v.id_venda)::numeric vendas
         FROM periodo p LEFT JOIN venda_medicamento v USING(id_periodo)
         GROUP BY p.id_periodo
       ),
       resumo AS (SELECT avg(vendas) media,stddev_pop(vendas) desvio FROM mensal),
       escores AS (SELECT m.id_periodo,m.vendas,
          CASE WHEN r.desvio IS NULL OR r.desvio=0 THEN 0 ELSE (m.vendas-r.media)/r.desvio END z
          FROM mensal m CROSS JOIN resumo r)
  SELECT count(*),string_agg(id_periodo||' (z='||round(z,2)||')',', ' ORDER BY id_periodo)
    INTO n_meses,outliers FROM escores WHERE abs(z)>3;
  SELECT count(*) INTO n_meses FROM periodo;
  IF n_meses<6 THEN RAISE EXCEPTION 'Série histórica insuficiente: % meses; mínimo 6',n_meses; END IF;
  IF outliers IS NOT NULL THEN RAISE EXCEPTION 'Anomalia mensal (|z-score| > 3): %',outliers; END IF;
  RAISE NOTICE 'Distribuição mensal: OK (% meses; nenhum |z-score| > 3)',n_meses;
END $$;

-- Prova de sensibilidade: uma série conhecida com um salto extremo precisa cruzar o limite.
DO $$
DECLARE z_max numeric;
BEGIN
  WITH serie AS (
    SELECT 100::numeric valor FROM generate_series(1,11)
    UNION ALL SELECT 10000::numeric
  ), resumo AS (SELECT avg(valor) media,stddev_pop(valor) desvio FROM serie)
  SELECT max(abs((s.valor-r.media)/NULLIF(r.desvio,0))) INTO z_max
  FROM serie s CROSS JOIN resumo r;
  IF z_max<=3 THEN RAISE EXCEPTION 'Autoteste estatístico falhou: salto extremo produziu z-score %',z_max; END IF;
  RAISE NOTICE 'Autoteste do detector estatístico: salto sintético detectado (z-score %)',round(z_max,2);
END $$;

DO $$
DECLARE origem bigint; fato bigint;
BEGIN
  SELECT count(*) INTO origem FROM venda_medicamento;
  SELECT count(*) INTO fato FROM fato_venda_medicamento;
  IF origem>0 AND origem<>fato THEN RAISE EXCEPTION 'Contagem origem/fato divergente: % / %',origem,fato; END IF;
  RAISE NOTICE 'Origem/fato dimensional: OK (% / %)',origem,fato;
END $$;
