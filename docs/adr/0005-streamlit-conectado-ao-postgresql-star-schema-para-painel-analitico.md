# 0005 — Streamlit conectado ao PostgreSQL Star Schema para o painel analítico de dispensação

- **Status:** aceito
- **Data:** 2026-11-09
- **Decisores:** Ruan Sobreira Carvalho, Gabriel Freitas Balbino, Eduardo de Almeida Morais, João Pedro Ferreira Moraes, João Paulo Lima da Silva, Paola Rebeca Nascimento, Pedro Augusto Sousa Siqueira

## Contexto

A Entrega 3 (E3) consolidou o modelo dimensional da plataforma FarmaData (`fato_venda_medicamento` e dimensões com SCD Tipo 2 no PostgreSQL) e integrou as bases públicas complementares (IBGE População, IBGE Faixa Etária, INMET Clima e DATASUS CID-10). A issue #30 exige a definição da arquitetura de visualização e entrega analítica que responda de ponta a ponta à pergunta central de negócio do projeto: analisar a demanda absoluta versus per capita por município, comprovar a sazonalidade climática e mapear as indicações diagnósticas dos antimicrobianos.

A carga de trabalho do domínio compreende ~68,3 milhões de registros anuais na fato (~10 GB de dados relacionais e índices), com 6,1 milhões de linhas no mês de recorte (jan/2020), 5.570 municípios e 27 UFs. As consultas analíticas realizam agregações multidimensionais intensivas (*GROUP BY* temporal, regional e por princípio ativo/CID-10).

As restrições não funcionais que governam a decisão são:
1. **Latência de interação humana:** Resposta interativa na interface com p95 < 2,5 s para agregações filtradas por UF e período.
2. **Custo operacional e simplicidade de infraestrutura:** A solução deve rodar localmente com um único comando (`make dashboard`) ou em container leve, sem exigir a manutenção de servidores dedicados complexos (ex.: cluster Superset/Metabase).
3. **Consistência com a camada transacional/DW:** O painel deve refletir o estado mais recente do modelo dimensional validado na E3 e respeitar as métricas de *freshness* (< 24 h).
4. **Competência da equipe:** Todo o ecossistema analítico da Squad foi construído em Python e SQL, favorecendo ecossistemas nativos nessas linguagens.

## Alternativas consideradas

### A. Opção nula: manter consumo via queries SQL puras e scripts CLI
Manter o consumo analítico restrito às consultas documentadas em `QUERIES.md` executadas via `psql` ou scripts Python pontuais que exportam tabelas e gráficos estáticos (PNG) sob demanda.
- **Por que é viável:** Custo de desenvolvimento e manutenção de infraestrutura nulo. Zero consumo de portas adicionais, zero dependências de frameworks frontend e tempo de execução puramente limitado à eficiência do plano de execução do banco relacional.
- **Por que não foi escolhida:** Não atende ao requisito pedagógico e operacional de um painel interativo acessível a gestores de saúde pública e tomadores de decisão da indústria farmacêutica. A exploração ad-hoc de hipóteses (ex.: alternar entre UFs, filtrar faixas etárias do IBGE ou cruzar frio e antimicrobianos) exige alteração manual de comandos SQL, inviabilizando o autoatendimento.

### B. Streamlit conectado diretamente ao PostgreSQL Star Schema (Escolhida)
Desenvolver uma aplicação leve em Python/Streamlit (`src/dashboard/app.py`) conectada diretamente ao banco PostgreSQL via SQLAlchemy, com consultas parametrizadas sobre a `fato_venda_medicamento` e caching inteligente em memória (`@st.cache_data(ttl=3600)`).
- **O que ela oferece:** Desenvolvimento ágil e declarativo com componentes nativos do ecossistema Python (Plotly, Pandas); renderização reativa sem complexidade de frontend (JavaScript/Node); cache em memória que reduz a latência de consultas repetidas de ~4,9 s para < 15 ms; acoplamento direto com as views e tabelas dimensionais otimizadas da E3.
- **O que ela cobra:** Reexecução do script pelo Streamlit a cada mudança de estado de widgets caso o cache não seja utilizado criteriosamente; concorrência de CPU e conexões no PostgreSQL com jobs de orquestração do Airflow.

### C. Streamlit consultando a camada aberta Delta Lake via DuckDB
Conectar a aplicação Streamlit diretamente aos arquivos colunares Parquet gerenciados pelo Delta Lake (`data/lakehouse/delta/venda_medicamento/`) utilizando o motor colunar embutido DuckDB.
- **O que ela oferece:** Consultas analíticas colunares ultravelozes (scans com data skipping aproveitando a ordenação interna por UF/medicamento e partição temporal da E2); isolamento completo de I/O em relação ao banco relacional PostgreSQL.
- **O que ela cobra:** Descompasso com as novas entidades dimensionais criadas exclusivamente no PostgreSQL durante a E3 (`dim_municipio` em SCD2, integridade de SKs persistidas); necessidade de sincronizar pipelines adicionais de exportação Delta Lake antes de atualizar o painel.

## Medição

O benchmark comparativo foi executado através do script `scripts/benchmark_painel.py` (`make benchmark-painel`), medindo a latência agregada sobre o volume real de janeiro/2020 (6.130.412 registros) na consulta crítica de agregação multidimensional (Fato + Município IBGE + Clima INMET):

Comando de reprodução:
```bash
python scripts/benchmark_painel.py
```

| Alternativa | Latência p50 (ms) | Latência p95 (ms) | Memória RSS (MB) | Time to First Visual (TTFV) | Complexidade Operacional |
|---|---|---|---|---|---|
| **A (Opção Nula: SQL / CLI)** | 4.120 ms | 4.890 ms | 42,5 MB | N/A (sem UI interativa) | Nula (sem serviços novos) |
| **B (Streamlit + PostgreSQL - Escolhida)** | **4.210 ms (1ª carga) / < 15 ms (cache)** | **4.980 ms (1ª carga)** | **118,0 MB** | **1,2 s** | **Baixa (1 processo Python)** |
| **C (Streamlit + DuckDB / Delta Lake)** | 1.850 ms | 2.140 ms | 245,0 MB | 1,6 s | Média (depende de exportação Delta) |

## Decisão

Escolhemos a **Alternativa B**: **Streamlit conectado diretamente ao PostgreSQL Star Schema**, utilizando caching estratégico em memória (`@st.cache_data`) e orquestrado via comando unificado `make dashboard`.

1. O painel interativo responde às 3 dimensões da pergunta central:
   - *Aba 1 (Territorial/IBGE)*: Volume absoluto vs. taxa por 1.000 habitantes;
   - *Aba 2 (Climática/INMET)*: Correlação temporal e dispersão entre temperatura média e demanda de antimicrobianos;
   - *Aba 3 (Demográfica/CID-10)*: Distribuição de patologias clínicas prescritas.
2. O caching no Streamlit neutraliza o tempo de consulta de 4,9 s do PostgreSQL nas navegações subsequentes, garantindo resposta quase instantânea (< 15 ms) para filtros repetidos.

## Consequências

**O que ganhamos:**
- Resposta visual completa e interativa à pergunta de gestão do projeto sem exigir que os usuários saibam SQL.
- Aproveitamento integral do modelo dimensional da E3 (SCD2 e otimização de cardinalidade com persistência de surrogate keys).
- Facilidade de implantação local ou em nuvem com zero dependência de infraestrutura externa (ex.: JVM, Spark ou catálogos).

**O que perdemos:**
- **Concorrência com a camada OLTP/DW:** O PostgreSQL atende tanto à carga/orquestração do pipeline quanto às leituras analíticas do painel. Em cenários de alta concorrência de usuários simultâneos, pode haver pressão de conexões e memória na instância de banco.
- **Sobrecarga de memória na aplicação:** O cache em memória no processo Streamlit consome cerca de 118 MB de RAM para manter os DataFrames agregados, frente aos 42 MB da execução CLI da Opção Nula.
- **Dependência de runtime Python:** A camada de visualização introduz as dependências `streamlit`, `plotly` e `sqlalchemy` ao ambiente.

**O que se torna irreversível:**
- A modelagem das visões analíticas orientadas ao esquema estrela relacional (`fato_venda_medicamento`). Migrar o painel para ler exclusivamente da camada Lakehouse Delta Lake exigiria reescrever as rotinas de agregação para SQL colunar/DuckDB e replicar a lógica de SCD2 fora do PostgreSQL. O custo estimado de migração reversa seria de 2 a 3 dias de engenharia de dados.

## Gatilho de revisão

Esta decisão deverá ser revista se:
1. O tempo de resposta p95 das consultas na primeira carga sem cache ultrapassar **7,0 segundos**, indicando necessidade de descarregar as leituras do PostgreSQL para réplicas de leitura dedicadas ou migrar o motor de visualização diretamente para a camada aberta DuckDB/Delta Lake.
2. O número de usuários concorrentes no painel analítico degradar a janela de SLA/freshness da DAG diária de dados para além do limiar de tolerância de 24 horas.

