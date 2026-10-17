# Diário de bordo — Semanas 7 a 10

> Registro das decisões, bloqueios e responsáveis da Squad para a Entrega 2 (issue #10).
> Ritual: reunião da Squad após as aulas de segunda e quarta de cada semana. Decisões
> pontuais fora desse ritual foram alinhadas por mensagem direta no grupo do WhatsApp da
> Squad e aplicadas direto no código/commit correspondente.

## Semana 7 — 22/09 a 28/09

Nos encontramos na segunda (22/09) e na quarta (24/09), logo depois da aula. Ruan modelou o
schema completo em sete etapas incrementais: geografia (UF/município), tempo, medicamento e
CID-10, conselho profissional e listas fixas da Anvisa, a tabela fato `venda_medicamento` com
seus índices, e por fim o Docker Compose com o README de reprodutibilidade completa. Junto
disso ele registrou a decisão de modelagem no ADR-001: insert-only normalizado, seguindo o
método de 6 passos da disciplina, e tornou o recorte de ano configurável via `ANO_RECORTE`
para não precisar recriar o schema a cada ajuste de escopo.

Eu (João Paulo) rodei o pipeline pela primeira vez e esbarrei em vários bloqueios de carga:
estouro de string no parser de CSV grande, cache de download falho e colunas reais do CSV do
SNGPC divergentes do que estava mapeado (`nu_ano_venda`, `sg_uf_venda` etc.), além de um
problema de idempotência no cache de período — corrigi tudo isso ainda na mesma semana e abri
o PR #1 com o Makefile e o `QUERIES.md` para padronizar os comandos de operação do projeto.
Eduardo documentou o uso de IA no projeto (`AI-USAGE.md`), por exigência da disciplina.

Os bloqueios de CSVs maiores do que o parser inicial suportava e de colunas divergentes da
documentação da fonte foram resolvidos ainda dentro da semana.

## Semana 8 — 29/09 a 05/10

Reunião na segunda (29/09) e na quarta (01/10). Eduardo otimizou o tempo de download e
inserção das tabelas do SNGPC (PR #2), resolvendo a lentidão e os erros que vínhamos
observando na primeira carga completa em Docker. Entre as reuniões, pelo WhatsApp da Squad,
alinhamos priorizar a estabilização da carga antes de avançar para as bases complementares da
E2, já que a ingestão do SNGPC ainda não rodava de ponta a ponta de forma confiável.

O bloqueio da semana — carga completa dos 12 meses ainda lenta e instável em Docker — foi
resolvido pelo próprio Eduardo nesse mesmo período.

## Semana 9 — 06/10 a 12/10

Na reunião de segunda (06/10) trouxemos a pauta da professora: confrontar o SNGPC com outras
bases públicas (issue #10). Fiquei (João Paulo) responsável por levantar e avaliar as fontes,
e entreguei o levantamento completo em `BASES_PUBLICAS.md`, avaliando seis bases candidatas —
IBGE população, IBGE faixa etária, DATASUS/CNES, DATASUS/SIA-SUS, FIRJAN/Atlas Brasil e INMET
— documentando para cada uma a granularidade, a licença e a pergunta nova que ela permite
responder.

Confirmamos por WhatsApp, fora da reunião de quarta, incorporar nesta entrega as três bases de
menor custo de integração: IBGE população por município, IBGE população por faixa etária e
INMET clima mensal por UF. CNES, SIA-SUS e FIRJAN/Atlas Brasil ficaram como candidatas para a
E3, por terem custo de ETL maior — o CNES só disponibiliza um dump de ~330 MB sem recorte, o
SIA-SUS exige conversão do formato DBC, e os portais do FIRJAN/Atlas Brasil são client-side e
não têm URL fixa de download. Implementei o preenchimento de `municipio.codigo_ibge` (que
resolveu de quebra uma dívida técnica do ADR), criei as tabelas
`ibge_populacao_municipio`, `ibge_populacao_faixa_etaria_municipio` e `clima_mensal_uf`, e
pluguei os respectivos scripts de carga no `docker-compose.yml`. Abri e mergeei o PR #11,
fechando a parte de bases públicas da issue #10.

Tive dois bloqueios nessa entrega: a API do INMET (`apitempo.inmet.gov.br`) respondia de
forma instável (404/204/500 inconsistentes), contornado usando o ZIP histórico estático do
portal; e a API do IBGE (tabela 9514, faixa etária) rejeitava pedir as 21 faixas etárias numa
única chamada, contornado fazendo uma chamada por faixa. Municípios com grafia muito
divergente entre Anvisa e IBGE ficaram sem `codigo_ibge` — registrei isso como limitação
conhecida, sem bloquear a entrega.

## Semana 10 — 13/10 (entrega)

Reunião de fechamento na segunda (13/10), antes da entrega marcada pela tag `e2`. Acertamos na
reunião e depois ajustamos detalhes pelo WhatsApp a divisão final de trabalho da E2: Eduardo
tornou a ingestão do SNGPC idempotente e reexecutável (PR #12, issue #3); Ruan construiu a
camada analítica/lakehouse, exportando `venda_medicamento` para Delta Lake sobre Parquet,
particionado por ano e mês, ordenado por UF/medicamento, com compressão ZSTD, compaction e
validação via DuckDB (PR #13, issues #5/#6); João Pedro detalhou a semântica at-least-once e
as chaves de idempotência de reprocessamento (PR #14, issue #7); Paola escreveu o ADR-E2 sobre
o mecanismo de ingestão, comparando CDC com recarga e Iceberg com Delta (PR #15, issue #9); e
eu fechei a issue #10 resumindo a tabela de status das bases complementares no `README.md` e
escrevendo este diário de bordo.

Ficaram em aberto, sem commits nesta janela, as issues #4 (CDC/captura de mudanças, atribuída
ao Gabriel Freitas) e #8 (tratamento de dado atrasado, atribuída ao Pedro Augusto) — candidatas
a entrar na E3. Não houve bloqueio novo nesta semana: foi uma semana de consolidação e
fechamento, encerrada com a tag `e2` sobre a main consolidada com todas as entregas acima.
