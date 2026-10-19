# Bases públicas complementares

> Levantamento para a Entrega 2 (issue #10): a professora pediu para confrontar o SNGPC com
> outras fontes, respondendo perguntas que a base isolada não permite (ex.: correlacionar
> venda de medicamentos com indicadores externos).

## Contexto da base atual

A granularidade do `venda_medicamento` é por **município × período (mês/ano de recorte) × medicamento
× (CID-10 quando antimicrobiano)**. Qualquer base externa só agrega valor se puder ser
cruzada numa dessas chaves.

**Bloqueio atual:** `municipio.codigo_ibge` existe na tabela mas **não é populado** na carga
(dívida técnica registrada no `ADR.md`). Esse é o pré-requisito para qualquer cruzamento com
IBGE/DATASUS por município — sem ele, só dá para cruzar por UF (`sigla_uf`) ou por nome de
município (frágil, sujeito a divergência de grafia).

## Bases avaliadas

### 1. IBGE — População por município (Estimativas de População / Censo 2022) ✅ incorporada
- **URL:** https://sidra.ibge.gov.br/ (SIDRA, tabela 6579 ou Censo 2022)
- **Granularidade:** município, anual
- **Formato/licença:** API REST ou CSV, dados abertos (sem restrição de uso)
- **Pergunta nova:** dispensações per capita por município — hoje só temos volume absoluto, que
  favorece município populoso independente de padrão de consumo real.
- **Pré-requisito:** popular `codigo_ibge` em `municipio`.
- **Status:** incorporada nesta entrega. `scripts/carregar_ibge_populacao.js` preenche
  `municipio.codigo_ibge` (casando nome normalizado + UF contra a lista oficial de municípios
  do IBGE) e grava a população do ano de recorte em `ibge_populacao_municipio`
  (`sql/08_ibge_populacao_municipio.sql`). O casamento por nome é best-effort — municípios com
  grafia muito divergente entre Anvisa e IBGE ficam sem `codigo_ibge` e sem população; o script
  loga quantos casaram e quantos não.

### 2. IBGE — Censo 2022, população por faixa etária e município ✅ incorporada
- **URL:** https://sidra.ibge.gov.br/ (Censo 2022, tabela 9514 — população por idade)
- **Granularidade:** município, faixa etária (grupos de 5 anos)
- **Formato/licença:** API REST, dados abertos
- **Pergunta nova:** a base já tem `idade_paciente`/`unidade_idade` para antimicrobianos —
  cruzando com a pirâmide etária do município dá para saber se o consumo por faixa etária é
  proporcional à população daquela faixa ou desproporcional (ex.: idosos consumindo mais que
  sua fração populacional).
- **Pré-requisito:** mesmo de #1 (`codigo_ibge`).
- **Status:** incorporada nesta entrega. `scripts/carregar_ibge_faixa_etaria.js` grava em
  `ibge_populacao_faixa_etaria_municipio` (`sql/10_ibge_populacao_faixa_etaria_municipio.sql`),
  reaproveitando o `codigo_ibge` preenchido pelo script da base #1. A API da tabela 9514 rejeita
  pedir todas as 21 faixas etárias numa única chamada (HTTP 500 por excesso de combinações) — o
  script faz uma chamada por faixa. Dado é do Censo 2022 (não varia por `ANO_RECORTE`, só existe
  esse ano). Municípios muito pequenos têm faixas com sigilo estatístico do IBGE (valor não
  numérico) — essas ficam sem registro para a faixa em questão.

### 3. DATASUS/CNES — Estabelecimentos de saúde por município ⚠️ avaliada, não incorporada
- **URL:** https://cnes.datasus.gov.br/ (download CSV mensal por competência)
- **Granularidade:** município, mensal
- **Formato/licença:** CSV/FTP, dados públicos DATASUS
- **Pergunta nova:** correlacionar densidade de farmácias/estabelecimentos no município com
  volume de dispensação — distingue "pouco consumo" de "pouca oferta".
- **Pré-requisito:** mesmo de #1.
- **Status:** reinvestigada e ainda não incorporada. O bloqueio de rede de entregas anteriores
  não se repetiu (FTP `ftp.datasus.gov.br/cnes/` respondeu normalmente), mas o dump disponível é
  `BASE_DE_DADOS_CNES_{competência}.ZIP` — um banco completo do CNES (todas as tabelas, não só
  estabelecimentos), com ~330 MB por mês. Maior custo de ETL do que uma base recortada
  justificaria para esta entrega. Fica como candidata para a E3.

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
- **Status:** reinvestigada e ainda não incorporada. Os dois portais são aplicações client-side
  (conteúdo renderizado em JS, sem link direto e estável para planilha/CSV por município) — não
  há uma URL de download fixa para automatizar como nas bases já incorporadas. Exigiria raspagem
  da aplicação ou localizar uma API interna não documentada. Fica como candidata para a E3.

### 6. INMET — Dados climáticos ✅ incorporada
- **URL:** https://portal.inmet.gov.br/dadoshistoricos
- **Granularidade:** estação meteorológica (não município), horária
- **Formato/licença:** ZIP anual com um CSV por estação, dados públicos
- **Pergunta nova:** sazonalidade de antimicrobianos por região/mês (ex.: pico de infecções
  respiratórias no inverno).
- **Observação:** granularidade por estação exige mapear estação → município/UF antes de
  juntar — maior esforço de ETL que as demais opções, e a correlação é só por UF/região, não
  por município.
- **Status:** incorporada nesta entrega. A API JSON do INMET (`apitempo.inmet.gov.br`) se
  mostrou instável nos testes (rotas documentadas respondendo `404`/`204`/`500` de forma
  inconsistente); o caminho usado foi o ZIP histórico estático
  (`portal.inmet.gov.br/uploads/dadoshistoricos/{ano}.zip`), que é confiável. O cabeçalho de
  cada CSV já traz a UF da estação, então `scripts/carregar_inmet.js` agrega direto por
  UF/mês — sem precisar resolver estação → município — e grava em `clima_mensal_uf`
  (`sql/09_clima_mensal_uf.sql`).

## Recomendação para esta entrega

Priorizar **IBGE — população por município (#1)**: mesma chave de integração (`codigo_ibge`),
API REST pronta para uso, resolve a dívida técnica do `codigo_ibge` em `municipio` como
subproduto, e responde diretamente à pergunta de per capita citada pela professora.

**INMET — clima mensal por UF (#6)** entrou também: o ZIP histórico é estável e o cabeçalho de
cada CSV já traz a UF, então não precisou resolver estação → município como o esforço inicial
sugeria.

**IBGE — população por faixa etária (#2)** entrou numa rodada seguinte: mesma chave
(`codigo_ibge`), mesma API, custo de integração baixo.

Essas três foram **incorporadas ao banco** (ver `sql/08_ibge_populacao_municipio.sql` +
`scripts/carregar_ibge_populacao.js`, `sql/09_clima_mensal_uf.sql` + `scripts/carregar_inmet.js`,
e `sql/10_ibge_populacao_faixa_etaria_municipio.sql` + `scripts/carregar_ibge_faixa_etaria.js`).

**CNES — estabelecimentos de saúde (#3)** foi reinvestigada: o acesso de rede que antes bloqueava
(API/FTP) voltou a funcionar, mas o dump do FTP é o banco completo do CNES (~330 MB/mês, todas as
tabelas) — custo de ETL maior que o justificável para esta entrega. Fica para a E3.

**FIRJAN/Atlas Brasil (#5)** também foi reinvestigada: os dois portais são aplicações client-side
sem URL fixa de download por município, então não há um caminho de automação simples. Fica para
a E3.

**SIA-SUS (#4)** segue registrada como candidata para a E3, por exigir conversão do formato DBC.
