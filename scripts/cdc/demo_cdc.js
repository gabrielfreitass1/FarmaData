#!/usr/bin/env node
/**
 * Demonstração de CDC: altera linhas de venda_medicamento no OLTP
 * (INSERT -> UPDATE -> DELETE) e prova que cada mudança atravessou
 * Postgres (WAL) -> Debezium -> Kafka, lendo os eventos do tópico.
 *
 * Uso (na raiz do projeto, Node 18+):
 *   node scripts/cdc/demo_cdc.js
 *
 * Pré-requisito: node scripts/cdc/registrar_conector.js já executado.
 * Saída também gravada em docs/cdc_evidencia.txt
 * Código de saída: 0 = os 3 eventos (c, u, d) chegaram; 1 = falhou.
 */
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const PG_USER = process.env.POSTGRES_USER || 'postgres';
const PG_DB = process.env.POSTGRES_DB || 'farmadata';
const CONNECT_URL = `http://localhost:${process.env.CONNECT_PORT || 8083}`;
const CONNECTOR = 'farmadata-venda-cdc';
const TOPICO = 'farmadata.public.venda_medicamento';
const TAG = `CDC-DEMO-${Date.now()}`;

const log = [];
function say(msg = '') {
  console.log(msg);
  log.push(msg);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function psql(sql) {
  return execFileSync(
    'docker',
    ['exec', 'farmadata_db', 'psql', '-U', PG_USER, '-d', PG_DB, '-At', '-v', 'ON_ERROR_STOP=1', '-c', sql],
    { encoding: 'utf8' }
  ).trim();
}

function lerTopico() {
  // Lê o tópico inteiro desde o início; termina sozinho após 6 s sem mensagens novas.
  let out = '';
  try {
    out = execFileSync(
      'docker',
      [
        'exec', 'farmadata_kafka', '/opt/kafka/bin/kafka-console-consumer.sh',
        '--bootstrap-server', 'localhost:9092',
        '--topic', TOPICO,
        '--from-beginning',
        '--timeout-ms', '6000',
      ],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 256 * 1024 * 1024 }
    );
  } catch (e) {
    // O consumidor sai com erro ao estourar o timeout; a saída parcial ainda vale.
    out = (e.stdout || '').toString();
  }
  return out
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.startsWith('{'))
    .map((l) => {
      try { return JSON.parse(l); } catch (_) { return null; }
    })
    .filter(Boolean);
}

const OPS = { c: 'INSERT', u: 'UPDATE', d: 'DELETE', r: 'SNAPSHOT' };

async function main() {
  say(`=== Demonstração CDC — venda_medicamento — ${new Date().toISOString()} ===`);
  say(`Marca desta execução (numero_notificacao): ${TAG}`);
  say();

  // 1) Validar que o conector realmente está consumindo o WAL
  say('--- 1) Pipeline ---');
  const walLevel = psql('SHOW wal_level');
  say(`wal_level: ${walLevel}`);
  const st = await (await fetch(`${CONNECT_URL}/connectors/${CONNECTOR}/status`)).json();
  say(`Conector: ${st.connector?.state} | tarefa: ${st.tasks?.[0]?.state}`);
  const slot = psql(
    "SELECT slot_name || ' | plugin=' || plugin || ' | active=' || active || ' | confirmed_flush_lsn=' || COALESCE(confirmed_flush_lsn::text,'-') " +
    "FROM pg_replication_slots WHERE slot_name='farmadata_slot'"
  );
  if (!slot) throw new Error('Slot de replicação farmadata_slot não existe. Rode registrar_conector.js.');
  say(`Slot de replicação: ${slot}`);
  if (st.connector?.state !== 'RUNNING' || st.tasks?.[0]?.state !== 'RUNNING') {
    throw new Error('Conector não está RUNNING.');
  }
  say();

  // 2) Alterações no OLTP
  say('--- 2) Alterações executadas no OLTP ---');
  // Usa chaves estrangeiras que já existem (dados da carga em lote).
  const sqlInsert =
    `INSERT INTO venda_medicamento (id_periodo, data_venda, id_municipio, id_medicamento, quantidade_vendida, eh_antimicrobiano, numero_notificacao, arquivo_origem) ` +
    `SELECT (SELECT MIN(id_periodo) FROM periodo), DATE '2020-01-15', ` +
    `(SELECT MIN(id_municipio) FROM municipio), (SELECT MIN(id_medicamento) FROM medicamento), ` +
    `1.500, FALSE, '${TAG}', 'cdc_demo' RETURNING id_venda`;
  say(`SQL> ${sqlInsert}`);
  let idVenda;
  try {
    idVenda = psql(sqlInsert).split('\n')[0];
  } catch (e) {
    throw new Error(
      'INSERT falhou. As tabelas periodo/municipio/medicamento precisam ter dados ' +
      '(rode a carga em lote antes). Detalhe: ' + (e.stderr || e.message)
    );
  }
  say(`   -> id_venda = ${idVenda}`);
  await sleep(1500);

  const sqlUpdate = `UPDATE venda_medicamento SET quantidade_vendida = 5.000 WHERE id_venda = ${idVenda}`;
  say(`SQL> ${sqlUpdate}`);
  psql(sqlUpdate);
  await sleep(1500);

  const sqlDelete = `DELETE FROM venda_medicamento WHERE id_venda = ${idVenda}`;
  say(`SQL> ${sqlDelete}`);
  psql(sqlDelete);
  say();

  // 3) Ler os eventos no destino (tópico Kafka)
  say(`--- 3) Eventos recebidos no tópico ${TOPICO} ---`);
  let meus = [];
  for (let tentativa = 1; tentativa <= 6; tentativa++) {
    const eventos = lerTopico();
    meus = eventos.filter((ev) => {
      const linha = ev.after || ev.before || {};
      return linha.numero_notificacao === TAG;
    });
    const ops = new Set(meus.map((e) => e.op));
    if (ops.has('c') && ops.has('u') && ops.has('d')) break;
    await sleep(2000);
  }

  meus.sort((a, b) => a.ts_ms - b.ts_ms);
  for (const ev of meus) {
    const nome = OPS[ev.op] || ev.op;
    const antes = ev.before ? `quantidade_vendida=${ev.before.quantidade_vendida}` : '(sem before)';
    const depois = ev.after ? `quantidade_vendida=${ev.after.quantidade_vendida}` : '(sem after)';
    say(`op=${ev.op} (${nome}) | lsn=${ev.source?.lsn} | before: ${antes} | after: ${depois}`);
  }
  say();

  // 4) Veredito
  const ops = meus.map((e) => e.op);
  const ok = ['c', 'u', 'd'].every((o) => ops.includes(o));
  say('--- 4) Resultado ---');
  if (ok) {
    say('SUCESSO: INSERT, UPDATE e DELETE feitos no OLTP chegaram ao Kafka como eventos op=c, op=u e op=d.');
  } else {
    say(`FALHA: eventos esperados c,u,d; recebidos: [${ops.join(',')}]. Veja: docker logs farmadata_connect`);
  }

  const dir = path.join(process.cwd(), 'docs');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'cdc_evidencia.txt'), log.join('\n') + '\n');
  console.log('\nEvidência salva em docs/cdc_evidencia.txt');
  process.exit(ok ? 0 : 1);
}

main().catch((e) => {
  console.error('ERRO:', e.message);
  process.exit(1);
});