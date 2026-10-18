#!/usr/bin/env node
/**
 * Registra (ou atualiza) o conector Debezium que captura o WAL da tabela
 * venda_medicamento e publica os eventos no Kafka.
 *
 * Também prepara o Postgres:
 *   - confirma wal_level=logical
 *   - REPLICA IDENTITY FULL na tabela (UPDATE/DELETE trazem a linha "before" completa)
 *
 * Uso (na raiz do projeto, Node 18+):
 *   node scripts/cdc/registrar_conector.js
 *
 * Variáveis opcionais: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, CONNECT_PORT
 */
const { execFileSync } = require('node:child_process');

const PG_USER = process.env.POSTGRES_USER || 'postgres';
const PG_PASS = process.env.POSTGRES_PASSWORD || 'postgres';
const PG_DB = process.env.POSTGRES_DB || 'farmadata';
const CONNECT_URL = `http://localhost:${process.env.CONNECT_PORT || 8083}`;
const CONNECTOR = 'farmadata-venda-cdc';

function psql(sql) {
  return execFileSync(
    'docker',
    ['exec', 'farmadata_db', 'psql', '-U', PG_USER, '-d', PG_DB, '-At', '-c', sql],
    { encoding: 'utf8' }
  ).trim();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function aguardarConnect() {
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`${CONNECT_URL}/connectors`);
      if (r.ok) return;
    } catch (_) { /* ainda subindo */ }
    await sleep(2000);
  }
  throw new Error(`Kafka Connect não respondeu em ${CONNECT_URL}. Os serviços estão no ar? (docker compose ps)`);
}

async function main() {
  // 1) Pré-requisitos no Postgres
  const walLevel = psql('SHOW wal_level');
  if (walLevel !== 'logical') {
    throw new Error(
      `wal_level=${walLevel}. Suba o db com o override: ` +
      'docker compose -f docker-compose.yml -f docker-compose.cdc.yml up -d db kafka connect'
    );
  }
  console.log('wal_level = logical');

  psql('ALTER TABLE venda_medicamento REPLICA IDENTITY FULL');
  console.log('REPLICA IDENTITY FULL aplicada em venda_medicamento');

  // 2) Registro idempotente do conector (PUT cria ou atualiza)
  await aguardarConnect();

  const config = {
    'connector.class': 'io.debezium.connector.postgresql.PostgresConnector',
    'plugin.name': 'pgoutput',
    'database.hostname': 'db',
    'database.port': '5432',
    'database.user': PG_USER,
    'database.password': PG_PASS,
    'database.dbname': PG_DB,
    'topic.prefix': 'farmadata',
    'table.include.list': 'public.venda_medicamento',
    'slot.name': 'farmadata_slot',
    'publication.name': 'farmadata_pub',
    'publication.autocreate.mode': 'filtered',
    // A tabela tem milhões de linhas da carga em lote: o CDC captura só o que muda
    // a partir de agora, sem reler o estado atual (snapshot).
    'snapshot.mode': 'no_data',
    // NUMERIC como string (o padrão seria bytes em base64, ilegível)
    'decimal.handling.mode': 'string',
    // JSON simples, sem o envelope de schema, para facilitar a leitura
    'key.converter': 'org.apache.kafka.connect.json.JsonConverter',
    'key.converter.schemas.enable': 'false',
    'value.converter': 'org.apache.kafka.connect.json.JsonConverter',
    'value.converter.schemas.enable': 'false',
    // Sem tombstone após DELETE: cada mudança vira exatamente um evento
    'tombstones.on.delete': 'false',
  };

  const resp = await fetch(`${CONNECT_URL}/connectors/${CONNECTOR}/config`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(config),
  });
  if (!resp.ok) {
    throw new Error(`Falha ao registrar conector (${resp.status}): ${await resp.text()}`);
  }
  console.log(`Conector "${CONNECTOR}" registrado (HTTP ${resp.status})`);

  // 3) Espera o conector ficar RUNNING
  for (let i = 0; i < 30; i++) {
    const s = await (await fetch(`${CONNECT_URL}/connectors/${CONNECTOR}/status`)).json();
    const estado = s.connector?.state;
    const tarefa = s.tasks?.[0]?.state;
    if (estado === 'RUNNING' && tarefa === 'RUNNING') {
      console.log('Conector RUNNING, tarefa RUNNING');
      return;
    }
    if (tarefa === 'FAILED') {
      throw new Error(`Tarefa do conector falhou:\n${s.tasks[0].trace}`);
    }
    await sleep(2000);
  }
  throw new Error('O conector não chegou ao estado RUNNING a tempo. Veja: docker logs farmadata_connect');
}

main().catch((e) => {
  console.error('ERRO:', e.message);
  process.exit(1);
});