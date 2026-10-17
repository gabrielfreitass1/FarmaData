# Queries principais

Consultas de apoio à pergunta de gestão do projeto (README.md): quais princípios
ativos, municípios e períodos concentram o maior volume de dispensações em 2020,
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
WHERE v.eh_antimicrobiano = TRUE
  AND v.id_unidade_idade = (SELECT id_unidade_idade FROM unidade_idade WHERE descricao = 'Anos')
  AND v.idade_paciente IS NOT NULL
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

## 7. Volume por tipo de receituário

```sql
SELECT tr.descricao,
       SUM(v.quantidade_vendida) AS quantidade_total,
       COUNT(*)                  AS total_dispensacoes
FROM venda_medicamento v
JOIN tipo_receituario tr ON tr.id_tipo_receituario = v.id_tipo_receituario
GROUP BY tr.descricao
ORDER BY quantidade_total DESC;
```

## 8. Cruzamento: princípio ativo x região x trimestre

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
