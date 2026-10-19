# ADR-002 — Mecanismo de Ingestão e Formato de Armazenamento Aberto (Issue #9)

**Status:** Aceito
**Data:** 2026-10-12  
**Squad:** FarmaData (UnB — Sistemas de Bancos de Dados 2)

---

## 1. Caracterizar a carga

| Dimensão | Caracterização |
|---|---|
| **Domínio** | Ingestão e consolidação analítica de dados de saúde pública: SNGPC/Anvisa, DATASUS (CID-10), IBGE (população) e INMET (clima). |
| **Padrão de atualização da origem** | Publicação em bateladas periódicas oficiais pelas agências de governo. Inexistência de transações OLTP contínuas. |
| **Volume estimado** | ~68,3 milhões de registros anuais na tabela fato de dispensações (~7 GB brutos de dados relacionais + ~3 GB de índices para por ano de análise), além de catálogos dimensionais. |
| **Taxa de escrita** | Bateladas volumosas esporádicas (mensais/anuais). Nenhuma concorrência de escrita durante a consulta analítica. |
| **Latência tolerada pelo negócio** | D-1 a D-30 perfeitamente aceitável. O dado oficial é retroativo e consolidado mensalmente; não há requisitos de monitoramento operacional em tempo real. |
| **Padrão de acesso analítico** | Leituras analíticas intensivas (*OLAP*), scans seletivos com filtros por período temporal, UF e princípio ativo, além de agregações multidimensionais (*GROUP BY*). |

---

## 2. Definir o problema

O projeto necessita evoluir o seu mecanismo de ingestão de dados e definir o padrão de armazenamento aberto na camada analítica (Lakehouse/OLAP), endereçando:

1. **Definição da estratégia de ingestão:** Avaliar a viabilidade de captura contínua de mudanças (*Change Data Capture — CDC*) versus recargas periódicas em lote, ponderando a latência contra o custo de infraestrutura.
2. **Superação da fragilidade da opção nula:** Os scripts atuais foram desenhados para uma inicialização única. Caso sejam agendados como estão para execuções periódicas, apresentam fragilidades no tratamento de erros 404.
3. **Seleção de formato de tabela aberta (Open Table Format):** Escolher entre **Apache Iceberg** e **Delta Lake** para viabilizar suporte transacional ACID, viagens no tempo (*time travel*) e facilidade de leitura por motores como DuckDB.
4. **Garantia de consistência e idempotência:** Assegurar que reexecuções de jobs não gerem duplicidade de registros.

---

## 3. Alternativas consideradas

| Alternativa | Mecanismo de Ingestão | Formato de Armazenamento | Descrição |
|---|---|---|---|
| **A — Opção Nula (Scripts crus agendados)** | Recarga periódica via cron chamando o container de carga | Armazenamento relacional PostgreSQL nativo | Agendar a reexecução do comando `docker compose run carga`. |
| **B — CDC Always-on + Delta Lake** | Captura contínua de mudanças (Debezium + Apache Kafka) | Delta Lake | Monitorar logs de transação da origem via conectores CDC em tempo real e descarregar no Delta Lake. |
| **C — Arquitetura Dual (Lote Idempotente + CDC Pedagógico) + Delta Lake** *(Escolhida)* | Recarga em lote agendada (Opção Nula Otimizada) + Debezium | Delta Lake sobre Parquet | Pipeline em lote mensal (idempotente via `DELETE` + `COPY`) para o volume massivo, em conjunto com o CDC ativado no Postgres para cumprir requisitos acadêmicos. |

---

## 4. Avaliação

### 4.1 Ingestão: CDC vs. Recarga Periódica (Opção Nula) vs. Arquitetura Dual

- **Opção Nula (Recarga Periódica em Lote):**
  * *Vantagem computacional:* Extremamente barata. Mantém-se ativa apenas durante o processamento mensal, liberando 100% de CPU e RAM no restante do tempo. Com as nossas otimizações, o `DROP INDEX` foi condicionado: os índices pesados só são removidos se houver $\ge 3$ arquivos mensais pendentes, preservando o desempenho em cargas incrementais simples.
  * *Desvantagem Arquitetural Original:* Inicialmente, o código em cadeia via `&&` (`npm install && node scripts/carregar_sngpc.js`) fazia com que um erro 404 (mês futuro) na Anvisa abortasse a carga com `process.exit(1)`, impedindo a atualização de bases subsequentes.

- **CDC (Change Data Capture — Debezium + Kafka):**
  * *Vantagem:* Reduz a latência de transferência a patamares de *near-real-time* e permite capturar exclusões (*hard deletes*) ocorridas no banco relacional.
  * *Desvantagem:* Incompatibilidade com o modelo de negócio (os dados públicos vêm em CSV, não de bancos com WAL) e custo operacional. Sustentar o ecossistema (Kafka, Zookeeper/KRaft, Debezium) exige alocação permanente de 2 a 4 GB de memória RAM e consumo ininterrupto de CPU. Contudo, a captura de mudanças é uma exigência pedagógica da disciplina.

### 4.2 Armazenamento: Apache Iceberg vs. Delta Lake

- **Apache Iceberg:**
  * Oferece arquitetura avançada para evolução de esquema (*Full Metadata-only Schema Evolution* via `field-id`) e *partition pruning* inteligente. No entanto, para funcionar plenamente com múltiplos motores, exige frequentemente a manutenção de um catálogo externo (REST Catalog, Nessie, Hive Metastore), adicionando complexidade operacional desnecessária para a escala deste projeto.

- **Delta Lake (Vencedor):**
  * A estrutura de metadados do Delta Lake baseia-se num log de transações em JSON (`_delta_log/`) armazenado diretamente no diretório dos dados, o que **elimina a necessidade de configurar catálogos externos**.
  * Ecossistema leve: Permite escritas em Python nativo usando a biblioteca `deltalake` (escrita em Rust), dispensando o uso de JVM/Spark. Além disso, o DuckDB (motor analítico escolhido) possui uma extensão oficial e altamente otimizada (`delta_scan`) para ler este formato nativamente.

---

## 5. Decisão

1. **Adotar a Arquitetura Dual de Ingestão (Lote + CDC):** 
   Embora o uso de CDC não se justifique do ponto de vista do negócio (dados públicos estáticos e retroativos), o projeto implementará o fluxo contínuo (Debezium + Kafka) a escutar o `farmadata_db` para atender estritamente aos requisitos curriculares da disciplina, mantendo em paralelo o processamento em lote como a fundação principal da carga volumosa.
2. **Refinar a Opção Nula em Lote:** O fluxo mensal de carga de CSVs torna-se a espinha dorsal de ingestão. A carga tornou-se condicional, idempotente e gerencia falhas sem abortar o processamento das outras bases do pipeline.
3. **Adotar o Delta Lake como Formato de Tabela Aberta:** Padronizar o armazenamento da camada analítica em Delta Lake sobre ficheiros Parquet, devido à sua simplicidade arquitetural (sem *catalog server*), alta compressão (ZSTD nível 3) e integração nativa via extensões do DuckDB.

---

## 6. Semântica de entrega e idempotência

A arquitetura adotará a semântica de entrega **At-least-once com convergência para Exactly-once lógico** por meio de operações idempotentes.

1. **Idempotência no PostgreSQL (Lote):** O limite transacional não é a linha, mas o `arquivo_origem`. Ao forçar uma recarga, a tabela fato sofre um `DELETE` transacional prévio das linhas exclusivas desse arquivo, seguido de um novo `COPY`. Isto garante que reprocessar um mês nunca gera duplicados.
2. **Idempotência no Delta Lake:** O script `exportar_delta.py` grava cada mês com `mode="overwrite"` restrito pela partição (`predicate="ano = A AND mes = M"`). A reexecução de um mês substitui integralmente a sua partição no Delta através de um commit atómico.
3. **Desacoplamento de Chaves de Origem e Destino:** No fluxo CDC, constatou-se que a recarga do lote reconstrói o `id_venda` sequencial. Consequentemente, operações analíticas e de reconciliação no Delta Lake baseadas nestes eventos devem recorrer a chaves de negócio (`arquivo_origem`, `numero_notificacao`), assumindo que a PK transacional é instável entre recargas pesadas.

---

## 7. Consequências

### Permite:
- **Redução de custos com Staging:** O Delta Lake permite leituras analíticas diretamente dos ficheiros Parquet compactados (12 ficheiros vs os 1500+ originais).
- **Semântica de Reescrita de Janela:** A adoção do modelo `overwrite` facilita o tratamento de atrasos pontuais e de republicações completas do SNGPC.
- **Interoperabilidade analítica:** O lakehouse pode ser consultado eficientemente pelo DuckDB em menos de 1 segundo para partições agregadas (como evidenciado no benchmark).

### Dívidas técnicas:
- O consumidor final do fluxo CDC. Atualmente, os eventos capturados via descodificação lógica chegam aos tópicos Kafka, mas a ferramenta de orquestração a jusante responsável por aplicá-los (`UPSERT`) de forma transacional na tabela Delta Lake transitará como dívida técnica para a Entrega E3.