# CDC — captura de mudanças do OLTP (E2, caminho 2)

Captura em tempo (quase) real o que muda na tabela `venda_medicamento` do Postgres, por **decodificação lógica do WAL** com **Debezium**, e entrega os eventos em um **tópico Kafka**.

```
 INSERT/UPDATE/DELETE        WAL lógico (pgoutput)         Kafka Connect            Kafka
┌──────────────────┐  slot  ┌─────────────────────┐      ┌───────────────┐      ┌────────────────────────────────┐
│ Postgres (db)    │ ─────► │ farmadata_slot      │ ───► │ Debezium      │ ───► │ farmadata.public.venda_        │
│ venda_medicamento│        │ publication         │      │ connector     │      │ medicamento                    │
└──────────────────┘        └─────────────────────┘      └───────────────┘      └────────────────────────────────┘
```

Cada evento tem `op` (`c` = insert, `u` = update, `d` = delete), `before` (linha antes), `after` (linha depois) e `source.lsn` (posição no WAL).

## Arquivos

| Arquivo | Função |
|---|---|
| `docker-compose.cdc.yml` | Override do compose: `db` com `wal_level=logical`, Kafka (KRaft) e Debezium Connect |
| `scripts/cdc/registrar_conector.js` | Valida pré-requisitos, aplica `REPLICA IDENTITY FULL` e registra o conector |
| `scripts/cdc/demo_cdc.js` | Altera linhas no OLTP e prova a propagação lendo o tópico |
| `docs/cdc_evidencia.txt` | Evidência gerada pela demonstração |

## Pré-requisitos

- Docker e Docker Compose
- Node.js 18+ no host (os scripts chamam `docker exec`)
- Banco já carregado (as tabelas `periodo`, `municipio` e `medicamento` precisam ter linhas, pois a demo usa chaves estrangeiras existentes)

## Passo a passo

Na raiz do projeto:

```bash
# 1) SUBA O DOCKER NORMALMENTE!!!
docker compose up
# Certifique-se que o docker subiu, rodou os scripts e caregou o banco completo
# 2) Subir Postgres com replicação lógica + Kafka + Debezium
#    (listar os serviços evita rodar a carga em lote de novo)
docker compose -f docker-compose.yml -f docker-compose.cdc.yml up -d db kafka connect

# 3) Aguardar ficar saudável (db, kafka e connect = healthy)
docker compose -f docker-compose.yml -f docker-compose.cdc.yml ps

# 4) Registrar o conector (também aplica REPLICA IDENTITY FULL)
node scripts/cdc/registrar_conector.js

# 5) Rodar a demonstração: INSERT -> UPDATE -> DELETE e leitura dos eventos
node scripts/cdc/demo_cdc.js
```

O volume `pgdata` é preservado: ao subir o `db` com o override, o Postgres só reinicia com `wal_level=logical`.

## Evidência esperada

A demo imprime (e salva em `docs/cdc_evidencia.txt`):

1. **Pipeline saudável:** `wal_level: logical`, conector e tarefa `RUNNING`, slot `farmadata_slot` com `active=true`.
2. **As alterações feitas no OLTP:** os três comandos SQL, com a marca `CDC-DEMO-<timestamp>` em `numero_notificacao`.
3. **Os eventos no destino**, algo como:

```
op=c (INSERT) | before: (sem before)            | after: quantidade_vendida=1.500
op=u (UPDATE) | before: quantidade_vendida=1.500 | after: quantidade_vendida=5.000
op=d (DELETE) | before: quantidade_vendida=5.000 | after: (sem after)
```

4. `SUCESSO` e código de saída 0. Se algum evento faltar, o script termina com código 1.

Para inspecionar o tópico manualmente:

```bash
docker exec farmadata_kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic farmadata.public.venda_medicamento --from-beginning
```

## Decisões de projeto

- **`snapshot.mode=no_data`:** a tabela tem milhões de linhas vindas da carga em lote. O CDC captura apenas mudanças a partir do registro do conector; o estado inicial já foi coberto pelo caminho em lote.
- **`REPLICA IDENTITY FULL`:** sem isso, UPDATE e DELETE trariam em `before` só a chave primária. Com FULL, `before` traz a linha inteira.
- **`decimal.handling.mode=string`:** `NUMERIC(10,3)` chegaria como bytes em base64 por padrão.
- **`tombstones.on.delete=false`:** cada mudança vira exatamente um evento.
- **Sem schema no JSON:** leitura mais simples dos eventos.

## Solução de problemas

| Sintoma | Causa provável / ação |
|---|---|
| `wal_level=replica` no registro | O `db` subiu sem o override. Rode o passo 1 com os dois `-f` |
| Conector `FAILED` | `docker logs farmadata_connect`; confira usuário/senha e se `db` está healthy |
| Demo não recebe eventos | Conector não `RUNNING`, ou slot inativo: `docker exec farmadata_db psql -U postgres -d farmadata -c "select * from pg_replication_slots"` |
| INSERT da demo falha por FK/NOT NULL | Tabelas de dimensão vazias: rode a carga em lote antes |
| Disco do Postgres crescendo | Slot parado retém WAL. Remova com `select pg_drop_replication_slot('farmadata_slot')` se desativar o CDC |

## Limpeza

```bash
# remover o conector e o slot
curl -X DELETE http://localhost:8083/connectors/farmadata-venda-cdc
docker compose -f docker-compose.yml -f docker-compose.cdc.yml stop kafka connect
```