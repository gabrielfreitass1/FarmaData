# Queries principais

Consultas de apoio à pergunta de gestão do projeto (README.md): quais princípios
ativos, municípios e períodos concentram o maior volume de dispensações no ano de análise,
e como esses padrões se distribuem por região e faixa etária.

Rode via `make psql` ou `docker compose exec db psql -U postgres -d farmadata`.

## 1. Top 10 princípios ativos por volume dispensado

```sql
SELECT m.principio_ativo,
       SUM(v.quantidade_vendida) AS quantidade_total,
       COUNT(*)                  AS total_dispensacoes
FROM venda_medicamento v
JOIN medicamento m ON m.id_medicamento = v.id_medicamento
GROUP BY m.principio_ativo
ORDER BY quantidade_total DESC
LIMIT 10;
```

## 2. Top 10 municípios por volume dispensado

```sql
SELECT mu.nome_municipio, mu.sigla_uf,
       SUM(v.quantidade_vendida) AS quantidade_total
FROM venda_medicamento v
JOIN municipio mu ON mu.id_municipio = v.id_municipio
GROUP BY mu.nome_municipio, mu.sigla_uf
ORDER BY quantidade_total DESC
LIMIT 10;
```

## 3. Evolução mensal de dispensações (sazonalidade)

```sql
SELECT p.ano, p.mes, p.nome_mes,
       SUM(v.quantidade_vendida) AS quantidade_total
FROM venda_medicamento v
JOIN periodo p ON p.id_periodo = v.id_periodo
GROUP BY p.ano, p.mes, p.nome_mes
ORDER BY p.ano, p.mes;
```

## 4. Distribuição por região do país

```sql
SELECT uf.regiao,
       SUM(v.quantidade_vendida) AS quantidade_total,
       COUNT(DISTINCT v.id_municipio) AS municipios_distintos
FROM venda_medicamento v
JOIN municipio mu ON mu.id_municipio = v.id_municipio
JOIN unidade_federativa uf ON uf.sigla = mu.sigla_uf
GROUP BY uf.regiao
ORDER BY quantidade_total DESC;
```

## 5. Antimicrobianos por faixa etária

```sql
SELECT CASE
           WHEN v.idade_paciente < 12  THEN '0-11 (criança)'
           WHEN v.idade_paciente < 18  THEN '12-17 (adolescente)'
           WHEN v.idade_paciente < 60  THEN '18-59 (adulto)'
           ELSE '60+ (idoso)'
       END AS faixa_etaria,
       COUNT(*) AS total_dispensacoes
FROM venda_medicamento v
WHERE v.eh_antimicrobiano AND v.idade_paciente IS NOT NULL
GROUP BY faixa_etaria
ORDER BY faixa_etaria;
```

## 6. Top 10 doenças (CID-10) associadas a antimicrobianos

```sql
SELECT c.codigo, c.descricao_abreviada,
       COUNT(*) AS total_dispensacoes
FROM venda_medicamento v
JOIN cid10 c ON c.codigo = v.codigo_cid10
WHERE v.eh_antimicrobiano = TRUE
GROUP BY c.codigo, c.descricao_abreviada
ORDER BY total_dispensacoes DESC
LIMIT 10;
```

## 7. Cruzamento: princípio ativo x região x trimestre

```sql
SELECT m.principio_ativo, uf.regiao, p.trimestre,
       SUM(v.quantidade_vendida) AS quantidade_total
FROM venda_medicamento v
JOIN medicamento m       ON m.id_medicamento = v.id_medicamento
JOIN municipio mu         ON mu.id_municipio = v.id_municipio
JOIN unidade_federativa uf ON uf.sigla = mu.sigla_uf
JOIN periodo p            ON p.id_periodo = v.id_periodo
GROUP BY m.principio_ativo, uf.regiao, p.trimestre
ORDER BY quantidade_total DESC
LIMIT 20;
```

## 8. Dispensações per capita por município (SNGPC + IBGE População)

Responde à pergunta: *O alto volume de vendas num município deve-se apenas ao tamanho da população ou há um padrão de consumo elevado?*

```sql
SELECT m.nome_municipio, m.sigla_uf,
       p.populacao,
       SUM(v.quantidade_vendida) AS total_vendido,
       ROUND((SUM(v.quantidade_vendida) / p.populacao) * 1000, 2) AS vendas_por_1000_hab
FROM venda_medicamento v
JOIN municipio m ON v.id_municipio = m.id_municipio
JOIN ibge_populacao_municipio p ON m.id_municipio = p.id_municipio
WHERE p.populacao > 50000 -- Filtro para evitar distorções de municípios muito pequenos
GROUP BY m.nome_municipio, m.sigla_uf, p.populacao
ORDER BY vendas_por_1000_hab DESC
LIMIT 10;
```


## 9. Sazonalidade climática e antimicrobianos (SNGPC + INMET)

Responde à pergunta: *Responde à pergunta: O volume de dispensação de antimicrobianos aumenta em meses de temperaturas mais baixas?*

```sql
WITH mensal AS (
  SELECT c.sigla_uf, v.id_periodo, c.temp_media_c, SUM(v.quantidade_vendida) AS vol
  FROM venda_medicamento v
  JOIN municipio m ON m.id_municipio = v.id_municipio
  JOIN clima_mensal_uf c ON c.sigla_uf = m.sigla_uf AND c.id_periodo = v.id_periodo
  WHERE v.eh_antimicrobiano
  GROUP BY c.sigla_uf, v.id_periodo, c.temp_media_c)
SELECT sigla_uf, ROUND(corr(temp_media_c, vol)::numeric, 2) AS correlacao, COUNT(*) AS meses
FROM mensal GROUP BY 1 ORDER BY correlacao; -- Ordena dos estados/meses mais frios para os mais quentes
LIMIT 15;
```

## 10. Comparativo etário em municípios focais (SNGPC + IBGE Faixa Etária)

Responde à pergunta: *Responde à pergunta: Como se distribui a pirâmide etária de um município específico para cruzamento futuro com as faixas de consumo de antimicrobianos?*

```sql
SELECT m.nome_municipio, m.sigla_uf, 
       f.faixa_etaria, 
       f.populacao
FROM ibge_populacao_faixa_etaria_municipio f
JOIN municipio m ON f.id_municipio = m.id_municipio
WHERE m.sigla_uf = 'DF' AND m.nome_municipio ILIKE 'BRAS%LIA'
ORDER BY f.populacao DESC;
```

Insight Analítico: A importação da pirâmide etária do IBGE revela que o DF tem uma forte concentração populacional entre os 20 e 49 anos, e uma base estreita (queda de natalidade em 0-4 anos). Isto viabiliza a transformação do volume absoluto de vendas de antimicrobianos (Query 5) em taxas de consumo proporcional por habitante de cada faixa etária, revelando o verdadeiro padrão de medicalização da população.