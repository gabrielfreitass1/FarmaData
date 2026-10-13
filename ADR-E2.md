# ADR-002 — Mecanismo de Ingestão e Formato de Armazenamento Aberto (Issue #9)

**Status:** Proposto  
**Data:** 2026-10-12  
**Squad:** FarmaData (UnB — Sistemas de Bancos de Dados 2)

---

## 1. Caracterizar a carga

| Dimensão | Caracterização |
|---|---|
| **Domínio** | Ingestão e consolidação analítica de dados de saúde pública: SNGPC/Anvisa, DATASUS (CID-10), IBGE (população e projeções demográficas) e INMET (séries climáticas históricas). |
| **Padrão de atualização da origem** | Publicação em bateladas periódicas oficiais pelas agências de governo (mensal para Anvisa; anual para projeções do IBGE e dados históricos do INMET; decenal para o Censo Demográfico). Inexistência de transações OLTP contínuas no sistema de origem. |
| **Volume estimado** | ~68,3 milhões de registros anuais na tabela fato de dispensações (~7 GB brutos de dados relacionais + ~3 GB de índices para 2020), além de catálogos dimensionais de 5.570+ municípios e 14.000+ categorias de CID-10. |
| **Taxa de escrita** | Bateladas volumosas esporádicas (mensais/anuais). Nenhuma concorrência de escrita durante a consulta analítica. |
| **Latência tolerada pelo negócio** | D-1 a D-30 perfeitamente aceitável. O dado oficial é retroativo e consolidado mensalmente; não há requisitos de monitoramento operacional em tempo real (*sub-second* ou *near-real-time*). |
| **Padrão de acesso analítico** | Leituras analíticas intensivas (*OLAP*), scans seletivos com filtros por período temporal, localidade geográfica (UF/Município) e princípio ativo, além de agregações multidimensionais (*GROUP BY* pesado). |

---

## 2. Definir o problema

O projeto necessita evoluir seu mecanismo de ingestão de dados e definir seu padrão de armazenamento aberto na camada analítica (Lakehouse/OLAP), endereçando:

1. **Definição da estratégia de ingestão:** Avaliar a viabilidade de captura contínua de mudanças (*Change Data Capture — CDC*) versus recargas periódicas em lote, ponderando a latência de negócio contra o custo de infraestrutura computacional.
2. **Superação da fragilidade da opção nula:** Os scripts atuais (`carregar_*.js` orquestrados via `docker-compose`) foram desenhados para uma inicialização única de banco e revelam falhas críticas caso sejam agendados como estão para execuções periódicas.
3. **Seleção de formato de tabela aberta (Open Table Format):** Escolher entre **Apache Iceberg** e **Delta Lake** para viabilizar desacoplamento entre armazenamento e processamento, suporte transacional ACID, viagens no tempo (*time travel*) e evolução de esquema sem reescrita de dados pesados.
4. **Garantia de consistência e idempotência:** Assegurar que falhas de rede, reexecuções de jobs ou dados sobrepostos na origem não gerem duplicidade de registros nem corrompam a série histórica.

---

## 3. Alternativas consideradas

| Alternativa | Mecanismo de Ingestão | Formato de Armazenamento | Descrição |
|---|---|---|---|
| **A — Opção Nula (Scripts crus agendados)** | Recarga periódica via cron chamando o container de carga existente | Armazenamento relacional PostgreSQL nativo | Agendar a reexecução do comando `docker compose run carga` com os scripts Node.js atuais. |
| **B — CDC Always-on + Delta Lake** | Captura contínua de mudanças (Debezium + Apache Kafka) | Delta Lake (formato Parquet com log de transações JSON) | Monitorar logs de transação da origem via conectores CDC em tempo real e descarregar no Delta Lake. |
| **C — Recarga Periódica Refatorada/Orquestrada + Apache Iceberg** *(Escolhida)* | Recarga em lote agendada desacoplada (Stage + `INSERT ... SELECT` / `MERGE`) | Apache Iceberg (árvore de metadados em camadas + Parquet) | Orquestração periódica de pipelines em lote com processamento vetorial/SQL, escrevendo em tabelas Apache Iceberg. |
| **D — Recarga Periódica Refatorada + Delta Lake** | Recarga em lote agendada desacoplada | Delta Lake | Pipeline em lote refatorado gravando em tabelas Delta Lake. |

---

## 4. Avaliação

### 4.1 Ingestão: CDC vs. Recarga Periódica (Opção Nula) vs. Recarga Refatorada

* **Opção Nula (Scripts crus agendados):**
  * *Vantagem computacional:* Extremamente barata em termos de ocupação de máquina, mantendo-se ativa por apenas **~0,07% do tempo mensal** (~30 minutos de processamento a cada ciclo de 43.200 minutos), liberando 100% de CPU e RAM entre janelas.
  * *Fragilidade arquitetural impeditiva:*
    1. **Quebra em cascata via `&&`:** Os scripts estão acoplados sequencialmente no `docker-compose.yml` (`npm install && node scripts/carregar_cid10.js && node scripts/carregar_sngpc.js && ...`). Caso o ano de recorte seja o corrente, os meses futuros retornam HTTP 404 na Anvisa, acionando `process.exit(1)` no script do SNGPC. Isso aborta o container e impede que as bases do IBGE e do INMET sejam executadas.
    2. **Falta de renovação de dados:** O script `carregar_cid10.js` não grava no banco; ele apenas regera um arquivo `.sql` de 1,9 MB que só é executado no primeiro boot pelo `docker-entrypoint-initdb.d` (inútil para instâncias com volume `pgdata` já criado). De forma similar, `carregar_inmet.js` verifica se o ZIP existe em `./tmp` e não refaz o download caso já esteja presente, estagnando o dado climático.
    3. **Degradação de leitura por remoção de índices:** O `carregar_sngpc.js` executa `DROP INDEX` na tabela inteira de 68M+ linhas para acelerar a carga de um único mês pendente. Durante todo o tempo de carga (10 a 25 minutos para 1 mês incremental), as consultas analíticas sofrem *sequential scans* de ~7 GB, violando os SLOs de latência (< 2 s).
    4. **Pico desproporcional de recursos:** A recriação final dos índices na base inteira aloca `maintenance_work_mem = '1GB'`, gerando um pico de até **~1,3 GB de RAM** e I/O massivo proporcional ao volume acumulado total $O(N \log N)$, e não ao delta do mês.

* **CDC (Change Data Capture — Debezium + Kafka):**
  * *Vantagem:* Reduz a latência de transferência a patamares de *near-real-time* e evita janelas batch que realizam leituras completas de arquivos.
  * *Desvantagem:* Incompatibilidade total com o modelo de negócio. Os dados públicos de origem (Anvisa, IBGE, INMET) não possuem bancos transacionais expostos com logs de replicação lógica (WAL/binlog); são despejos estáticos disponibilizados em arquivos (CSV/ZIP) ou APIs REST públicas. Além disso, sustentar um ecossistema *always-on* (Kafka Brokers, Kafka Connect, Debezium, Zookeeper/KRaft) exigiria alocação permanente de 2 a 4 GB de memória RAM e consumo ininterrupto de CPU para processar eventos que ocorrem apenas uma vez ao mês. O custo financeiro e a complexidade operacional não se justificam para um domínio que tolera perfeitamente D-1 ou D-30.

* **Recarga Periódica Refatorada/Orquestrada:**
  * Elimina o encadeamento rígido via `&&`, isolando os jobs de cada fonte.
  * Substitui a lógica imperativa do Node.js por comandos declarativos orientados a conjunto (`INSERT ... SELECT` / `MERGE INTO`), permitindo cargas incrementais em camadas de *staging* temporárias sem necessidade de derrubar índices da tabela final de produção.

### 4.2 Armazenamento: Apache Iceberg vs. Delta Lake

* **Delta Lake:**
  * O Delta Lake estrutura seus metadados através de um log sequencial de commits em formato JSON (`_delta_log/000...json`) complementado por arquivos periódicos de checkpoint em Parquet.
  * Embora eficiente e com forte maturidade no ambiente Spark/Databricks, a evolução de esquema no Delta Lake historicamente dependia do mapeamento direto por nome físico da coluna ou índice posicional, o que gerava gargalos ou exigia a reescrita de dados pesados ao renomear ou reorganizar colunas profundas (embora o recurso `column mapping` tenha reduzido parte dessa limitação, ainda mantém dependências de versão do protocolo). Ademais, sua integração nativa com múltiplos motores analíticos concorrentes (ex: Trino, DuckDB, ClickHouse) ainda encontra disparidades em relação ao motor proprietário.

* **Apache Iceberg (Vencedor):**
  * **Evolução de Esquema Independente (Full Metadata-only Schema Evolution):** O Apache Iceberg rastreia cada campo por um identificador inteiro numérico único e imutável (`field-id`), desacoplado completamente do nome da coluna ou de sua posição ordinal. Com isso, operações de renomeação de colunas, reordenação, adição ou remoção de campos (frequentes em dados públicos da Anvisa e do IBGE que alteram cabeçalhos entre publicações anuais) ocorrem **exclusivamente na camada de metadados**, com custo computacional instantâneo ($O(1)$) e sem a necessidade de reescrever um único byte dos arquivos Parquet de dados subjacentes.
  * **Arquitetura de Metadados Hierárquica:** A estrutura em três camadas do Iceberg (*Iceberg Catalog* $\rightarrow$ *Metadata File* $\rightarrow$ *Manifest List* $\rightarrow$ *Manifest Files* $\rightarrow$ *Data Files*) permite *partition pruning* e *min/max stats pruning* no nível de metadados antes de qualquer leitura em disco, otimizando drasticamente consultas temporais e geográficas.
  * **Ecossistema Aberto e Agnóstico:** O Iceberg foi concebido sob governança aberta da Apache Software Foundation, apresentando paridade de leitura e escrita de primeira classe em múltiplos motores analíticos sem acoplamento a um único vendor (Trino, DuckDB, Apache Spark, Apache Flink, StarRocks).

---

## 5. Decisão

1. **Descartar o CDC (*Change Data Capture*):** A arquitetura orientada a eventos contínuos é rejeitada pelo alto custo de manter containers *always-on* e pela total inadequação à dinâmica de publicação das fontes governamentais (arquivos mensais/anuais).
2. **Descartar a Opção Nula Crua:** Rejeita-se o simples agendamento dos scripts atuais (`carregar_*.js`) no cron devido à sua fragilidade diante de erros 404 (SNGPC), incapacidade de atualizar CID-10/INMET sem reinicialização destrutiva do banco e severa degradação de performance por remoção global de índices.
3. **Adotar a Recarga Periódica Refatorada e Orquestrada:**
   - Adotar pipelines em lote programados em janelas mensais.
   - Utilizar uma camada de aterrissagem (*Landing/Staging Zone*) desacoplada.
   - Executar transformações e resolução de domínios diretamente via comandos SQL baseados em processamento em lote (`INSERT ... SELECT` / `MERGE INTO`), eliminando a queda dos índices de produção durante a carga.
4. **Adotar o Apache Iceberg como Formato de Tabela Aberta:**
   - Padronizar o armazenamento da camada analítica em **Apache Iceberg**, garantindo evolução contínua de esquema via `field-id` sem reescrita de dados históricos e assegurando liberdade de escolha para o motor de consulta analítica.

---

## 6. Semântica de entrega e idempotência

A arquitetura adotará a semântica de entrega **At-least-once com convergência para Exactly-once lógico** por meio de operações rigorosamente idempotentes.

1. **Tratamento de Duplicidades via `MERGE INTO`:**
   - Em vez de operações de inserção cega (`INSERT APPEND`), as cargas nas tabelas Iceberg utilizarão comandos transacionais baseados em chaves de negócio e metadados de rastreabilidade (ex: `codigo_municipio`, `id_periodo`, `arquivo_origem`, `hash_linha`):
     ```sql
     MERGE INTO lakehouse.farmadata.venda_medicamento AS target
     USING staging.stg_venda_medicamento AS source
     ON target.id_periodo = source.id_periodo 
        AND target.id_municipio = source.id_municipio
        AND target.id_medicamento = source.id_medicamento
        AND target.numero_notificacao = source.numero_notificacao
     WHEN MATCHED THEN
       UPDATE SET target.quantidade_vendida = source.quantidade_vendida
     WHEN NOT MATCHED THEN
       INSERT (id_periodo, data_venda, id_municipio, id_medicamento, quantidade_vendida, ...)
       VALUES (source.id_periodo, source.data_venda, source.id_municipio, source.id_medicamento, source.quantidade_vendida, ...);
     ```
   - Alternativamente, para dados com granularidade estritamente mensal e imutável (como o SNGPC), utilizar-se-á a substituição atômica de partição (*Dynamic Partition Overwrite*), garantindo que a reexecução de um mês substitua integralmente os dados daquele período sem gerar duplicações.

2. **Isolamento de Snapshot e Transações ACID:**
   - Cada operação de ingestão no Iceberg cria um snapshot atômico independente. Leituras analíticas em produção nunca visualizam dados parciais ou em estado intermediário de carga. Se o job falhar na metade (ex: erro de rede ou interrupção do container), o snapshot com falha é descartado sem impactar as consultas dos usuários.

3. **Tabela de Auditoria e Controle de Ingestão:**
   - O controle já inaugurado pela tabela `carga_arquivo` será preservado e expandido. Um lote de arquivo só é considerado promovido à camada final após o commit atômico do snapshot no catálogo Iceberg e o registro de sua assinatura (nome do arquivo, timestamp, contagem de linhas lidas/inseridas e checksum).

---

## 7. Consequências

### Permite:
* **Redução drástica de custos operacionais:** Recursos computacionais de processamento são alocados sob demanda estritamente durante a janela de execução da batelada (~0,07% do tempo mensal), sem desperdício de infraestrutura *always-on*.
* **Resiliência a mudanças de esquema:** Adaptação ágil a alterações de leiaute da Anvisa ou do IBGE (adição/renomeação de colunas) sem quebrar pipelines legados e sem exigir reescritas caras de dados em repouso.
* **Preservação de SLOs de leitura analítica:** O motor de consulta continua respondendo a agregações em < 2 s mesmo durante o processamento de novas cargas, pois não há mais remoção de índices ou tabelas bloqueadas durante a ingestão.
* **Interoperabilidade analítica:** O lakehouse poderá ser consultado de forma intercambiável por diferentes motores SQL (Trino, DuckDB, Spark) diretamente sobre os metadados do Iceberg.

### Impede/dificulta:
* **Ingestão com latência sub-minuto:** O modelo não atende cenários de mensageria em tempo real (Streaming/Event-driven), os quais são declaradamente desnecessários para a tomada de decisão deste domínio.
* **Execução dos scripts legados sem refatoração prévia:** Os arquivos atuais em `scripts/` precisam ser modificados para desmembrar a execução e introduzir a separação em camadas (*Staging/Raw* $\rightarrow$ *Trusted/Lakehouse*).

### Dívidas técnicas:
* Implementar a orquestração desacoplada (via script/Makefile avançado ou orquestrador leve como cron/Airflow/Dagster), tratando individualmente o código de saída de cada fonte.
* Configurar e manter um catálogo Iceberg (ex: Nessie, Hive Metastore ou JDBC Catalog) integrado ao motor de processamento.

