# Bases públicas complementares

> Levantamento para a Entrega 2 (issue #10): a professora pediu para confrontar o SNGPC com
> outras fontes, respondendo perguntas que a base isolada não permite (ex.: correlacionar
> venda de medicamentos com indicadores externos).

## Contexto da base atual

A granularidade do `venda_medicamento` é por **município × período (mês/2020) × medicamento
× (CID-10 quando antimicrobiano)**. Qualquer base externa só agrega valor se puder ser
cruzada numa dessas chaves.

**Bloqueio atual:** `municipio.codigo_ibge` existe na tabela mas **não é populado** na carga
(dívida técnica registrada no `ADR.md`). Esse é o pré-requisito para qualquer cruzamento com
IBGE/DATASUS por município — sem ele, só dá para cruzar por UF (`sigla_uf`) ou por nome de
município (frágil, sujeito a divergência de grafia).

## Bases avaliadas

### 1. IBGE — População por município (Estimativas de População / Censo 2022)
- **URL:** https://sidra.ibge.gov.br/ (SIDRA, tabela 6579 ou Censo 2022)
- **Granularidade:** município, anual
- **Formato/licença:** API REST ou CSV, dados abertos (sem restrição de uso)
- **Pergunta nova:** dispensações per capita por município — hoje só temos volume absoluto, que
  favorece município populoso independente de padrão de consumo real.
- **Pré-requisito:** popular `codigo_ibge` em `municipio`.

### 2. IBGE — Censo 2022, população por faixa etária e município
- **URL:** https://sidra.ibge.gov.br/ (Censo 2022, tabela de população por idade)
- **Granularidade:** município, faixa etária
- **Formato/licença:** API REST ou CSV, dados abertos
- **Pergunta nova:** a base já tem `idade_paciente`/`unidade_idade` para antimicrobianos —
  cruzando com a pirâmide etária do município dá para saber se o consumo por faixa etária é
  proporcional à população daquela faixa ou desproporcional (ex.: idosos consumindo mais que
  sua fração populacional).
- **Pré-requisito:** mesmo de #1 (`codigo_ibge`).

### 3. DATASUS/CNES — Estabelecimentos de saúde por município
- **URL:** https://cnes.datasus.gov.br/ (download CSV mensal por competência)
- **Granularidade:** município, mensal
- **Formato/licença:** CSV/FTP, dados públicos DATASUS
- **Pergunta nova:** correlacionar densidade de farmácias/estabelecimentos no município com
  volume de dispensação — distingue "pouco consumo" de "pouca oferta".
- **Pré-requisito:** mesmo de #1.

### 4. DATASUS/SIA-SUS — Atendimentos ambulatoriais por CID
- **URL:** https://datasus.saude.gov.br/transferencia-de-arquivos/ (SIA, produção ambulatorial)
- **Granularidade:** município, mensal, por CID-10
- **Formato/licença:** CSV (formato DBC do DATASUS, requer conversão), dados públicos
- **Pergunta nova:** a base já tem `cid10` em `venda_medicamento` — cruzar com atendimentos
  ambulatoriais pelo mesmo CID mostra se o volume de antimicrobiano dispensado acompanha o
  volume de diagnóstico, ou se há dispensação fora do atendimento formal (indício de uso
  indevido/automedicação).
- **Observação:** formato DBC é mais trabalhoso de converter que CSV simples — maior custo de
  integração que as opções 1-3.

### 5. FIRJAN (IFDM) / Atlas Brasil (IDHM) — Índice de desenvolvimento municipal
- **URL:** https://www.firjan.com.br/ifdm/ ou http://www.atlasbrasil.org.br/
- **Granularidade:** município, anual (FIRJAN defasado ~2 anos; Atlas Brasil é por Censo)
- **Formato/licença:** planilha XLS/CSV para download, dados públicos (Atlas Brasil é
  convênio PNUD/IPEA/FJP, uso livre com atribuição)
- **Pergunta nova:** correlacionar renda/desenvolvimento socioeconômico do município com
  padrão de consumo (ex.: antimicrobianos de maior custo concentrados em municípios de IDHM
  mais alto).
- **Observação:** Atlas Brasil é anual por Censo (2010/2022) — granularidade temporal mais
  grosseira que os dados mensais do SNGPC; serve para cruzar "perfil do município", não
  tendência mensal.

### 6. INMET — Dados climáticos
- **URL:** https://portal.inmet.gov.br/dadoshistoricos
- **Granularidade:** estação meteorológica (não município), diária
- **Formato/licença:** CSV por ano/estação, dados públicos
- **Pergunta nova:** sazonalidade de antimicrobianos por região/mês (ex.: pico de infecções
  respiratórias no inverno).
- **Observação:** granularidade por estação exige mapear estação → município/UF antes de
  juntar — maior esforço de ETL que as demais opções, e a correlação é só por UF/região, não
  por município.

## Recomendação para esta entrega

Priorizar **IBGE — população por município (#1)** e **CNES — estabelecimentos de saúde (#3)**:
mesma chave de integração (`codigo_ibge`), dados abertos em CSV/API prontos para uso, e
respondem diretamente a perguntas que a professora citou (per capita e oferta de saúde).

Isso implica resolver antes a dívida técnica do `codigo_ibge` em `municipio` — tarefa prévia
e necessária para qualquer uma das bases listadas, não só para esta entrega.

As demais (SIA-SUS, FIRJAN/Atlas Brasil, INMET) ficam registradas como candidatas para a E3,
por exigirem conversão de formato (SIA-SUS) ou terem granularidade temporal/espacial mais
grosseira que o SNGPC (FIRJAN/Atlas Brasil, INMET).
