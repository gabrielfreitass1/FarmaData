// Carga dos CSVs SNGPC/Anvisa (EDA_Industrializados_AAAAMM.csv) via COPY.
// Uso: DATABASE_URL=postgres://... node scripts/carregar_sngpc.js
//
// Características:
//  - 1 arquivo por mês, baixado para .part e renomeado só ao terminar
//  - 2 passadas por arquivo: (1) resolve dimensões, (2) COPY em streaming
//    (nenhuma consulta na conexão enquanto o COPY está aberto, sem acumular linhas em memória)
//  - cada arquivo é carregado em UMA transação junto com o registro em carga_arquivo
//    => rodar de novo pula o que já foi carregado (idempotente)
//  - linhas inválidas são rejeitadas e contadas por motivo (nada de valores default)
//  - índices são removidos antes da carga e criados no final

'use strict';

const fs = require('fs');
const readline = require('readline');
const path = require('path');
const https = require('https');
const { Client } = require('pg');
const { from: copyFrom } = require('pg-copy-streams');
const { pipeline } = require('stream/promises');
const { Readable } = require('stream');

// ---------------------------------------------------------------------------
// Configuração
// ---------------------------------------------------------------------------
const ANO = parseInt(process.env.ANO_RECORTE || '2020', 10);
const BASE_URL = 'https://dados.anvisa.gov.br/dados/SNGPC/Industrializados';
const MESES = ['01','02','03','04','05','06','07','08','09','10','11','12'];
const CSV_SEPARADOR = ';';
const CSV_ENCODING = 'latin1'; // arquivos da Anvisa: Windows-1252
const TMP_DIR = path.resolve(__dirname, '../tmp');
const LOTE_COPY = 5000;
const SEP = '\u0001'; // separador interno de chaves

const UFS = new Set(['AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA',
  'PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO']);
const SEXO = { '1': 'M', '2': 'F' };

const cachePeriodo = new Map();
const cacheMunicipio = new Map();
const cacheMedicamento = new Map();
let catalogoCid = null; // Set de códigos CID-10 (null = indisponível)

// ---------------------------------------------------------------------------
// Utilitários
// ---------------------------------------------------------------------------
const limpar = (v) => {
  if (v === undefined || v === null) return null;
  const s = String(v).trim().replace(/^"(.*)"$/, '$1').trim();
  return s.length ? s : null;
};

// Escape para COPY FORMAT text
const esc = (v) =>
  v === null || v === undefined
    ? '\\N'
    : String(v).replace(/\\/g, '\\\\').replace(/[\t\r\n]/g, ' ');

const fmtSeg = (ms) => `${Math.round(ms / 1000)}s`;

function baixarArquivo(url, destino, redirecoes = 0) {
  return new Promise((resolve, reject) => {
    if (redirecoes > 5) return reject(new Error('redirecionamentos demais'));
    const tmp = destino + '.part';
    const req = https.get(url, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
        res.resume();
        return baixarArquivo(new URL(res.headers.location, url).toString(), destino, redirecoes + 1)
          .then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`HTTP ${res.statusCode} ao baixar ${url}`));
      }
      const esperado = parseInt(res.headers['content-length'] || '0', 10);
      let recebido = 0;
      res.on('data', (c) => (recebido += c.length));
      const out = fs.createWriteStream(tmp);
      res.pipe(out);
      const falhar = (err) => {
        out.destroy();
        fs.rmSync(tmp, { force: true });
        reject(err);
      };
      res.on('error', falhar);
      res.on('aborted', () => falhar(new Error('conexão interrompida')));
      out.on('error', falhar);
      out.on('finish', () => {
        if (esperado && recebido !== esperado) {
          return falhar(new Error(`download incompleto (${recebido}/${esperado} bytes)`));
        }
        fs.renameSync(tmp, destino);
        resolve();
      });
    });
    req.setTimeout(60000, () => req.destroy(new Error('timeout no download')));
    req.on('error', (err) => {
      fs.rmSync(tmp, { force: true });
      reject(err);
    });
  });
}

async function baixarComRetry(url, destino, tentativas = 3) {
  let ultimo;
  for (let i = 1; i <= tentativas; i++) {
    try {
      return await baixarArquivo(url, destino);
    } catch (err) {
      ultimo = err;
      if (/HTTP 404/.test(err.message)) break; // não adianta repetir
      console.warn(`  [AVISO] tentativa ${i}/${tentativas} falhou: ${err.message}`);
    }
  }
  throw ultimo;
}

// ---------------------------------------------------------------------------
// Banco: estrutura auxiliar e caches
// ---------------------------------------------------------------------------
async function garantirCargaArquivo(client) {
  await client.query(`
    CREATE TABLE IF NOT EXISTS carga_arquivo (
      arquivo          TEXT PRIMARY KEY,
      linhas_lidas     BIGINT NOT NULL,
      linhas_inseridas BIGINT NOT NULL,
      linhas_rejeitadas BIGINT NOT NULL,
      motivos_rejeicao JSONB NOT NULL DEFAULT '{}'::jsonb,
      carregado_em     TIMESTAMPTZ NOT NULL DEFAULT now()
    )`);
}

async function garantirPeriodos(client, ano) {
  const NOMES = ['Janeiro','Fevereiro','Março','Abril','Maio','Junho',
    'Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'];
  const p2 = (n) => String(n).padStart(2, '0');
  for (let m = 1; m <= 12; m++) {
    const id = ano * 100 + m;
    const ultimoDia = new Date(Date.UTC(ano, m, 0)).getUTCDate();
    await client.query(
      `INSERT INTO periodo (id_periodo, ano, mes, nome_mes, trimestre, semestre, data_inicio, data_fim)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT (id_periodo) DO NOTHING`,
      [id, ano, m, NOMES[m - 1], Math.ceil(m / 3), m <= 6 ? 1 : 2,
        `${ano}-${p2(m)}-01`, `${ano}-${p2(m)}-${p2(ultimoDia)}`]
    );
    cachePeriodo.set(String(id), id);
  }
  console.log(`[OK] Períodos de ${ano} verificados.`);
}

async function recarregarCacheMunicipio(client) {
  const r = await client.query('SELECT id_municipio, nome_municipio, sigla_uf FROM municipio');
  cacheMunicipio.clear();
  for (const x of r.rows) cacheMunicipio.set(x.nome_municipio + SEP + x.sigla_uf, x.id_municipio);
}

async function recarregarCacheMedicamento(client) {
  const r = await client.query(
    'SELECT id_medicamento, principio_ativo, descricao_apresentacao FROM medicamento');
  cacheMedicamento.clear();
  for (const x of r.rows) {
    cacheMedicamento.set(x.principio_ativo + SEP + x.descricao_apresentacao, x.id_medicamento);
  }
}

async function carregarCatalogoCid(client) {
  try {
    const pk = await client.query(`
      SELECT a.attname FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
      WHERE i.indrelid = 'cid10'::regclass AND i.indisprimary LIMIT 1`);
    const col = pk.rows[0].attname;
    const r = await client.query(`SELECT "${col}" AS codigo FROM cid10`);
    catalogoCid = new Set(r.rows.map((x) => String(x.codigo).toUpperCase()));
    console.log(`[OK] Catálogo CID-10: ${catalogoCid.size} códigos (coluna ${col}).`);
    if (catalogoCid.size === 0) throw new Error('tabela cid10 vazia');
  } catch (err) {
    catalogoCid = null;
    console.warn(`[AVISO] Catálogo CID-10 indisponível (${err.message}). CID será gravado como NULL.`);
  }
}

const INDICES_ANTIGOS = [
  'idx_venda_periodo', 'idx_venda_data', 'idx_venda_medicamento', 'idx_venda_municipio',
  'idx_venda_municipio_periodo', 'idx_venda_medicamento_periodo', 'idx_venda_antimicrobiano',
  'idx_venda_periodo_municipio'
];

async function removerIndices(client) {
  console.log('[+] Removendo índices para acelerar a carga...');
  for (const i of INDICES_ANTIGOS) await client.query(`DROP INDEX IF EXISTS ${i}`);
}

async function criarIndices(client) {
  console.log('[+] Criando índices (pode levar alguns minutos)...');
  await client.query("SET maintenance_work_mem = '1GB'");
  const t0 = Date.now();
  await client.query('CREATE INDEX IF NOT EXISTS idx_venda_periodo_municipio ON venda_medicamento(id_periodo, id_municipio)');
  await client.query('CREATE INDEX IF NOT EXISTS idx_venda_municipio_periodo ON venda_medicamento(id_municipio, id_periodo)');
  await client.query('CREATE INDEX IF NOT EXISTS idx_venda_medicamento_periodo ON venda_medicamento(id_medicamento, id_periodo)');
  await client.query('CREATE INDEX IF NOT EXISTS idx_venda_antimicrobiano ON venda_medicamento(id_periodo, id_municipio) WHERE eh_antimicrobiano = TRUE');
  await client.query('ANALYZE venda_medicamento');
  console.log(`[OK] Índices criados em ${fmtSeg(Date.now() - t0)}.`);
}

// ---------------------------------------------------------------------------
// Leitura do CSV
// ---------------------------------------------------------------------------
async function* lerRegistros(caminho) {
  const rl = readline.createInterface({
    input: fs.createReadStream(caminho, { encoding: CSV_ENCODING }),
    crlfDelay: Infinity
  });
  let col = null;
  for await (const bruta of rl) {
    const linha = bruta.replace(/^\uFEFF/, '').trim();
    if (!linha) continue;
    if (!col) {
      col = {};
      linha.split(CSV_SEPARADOR).forEach((h, i) => {
        col[h.trim().replace(/^"(.*)"$/, '$1').toLowerCase().replace(/[^a-z0-9_]/g, '_')] = i;
      });
      if (col.nu_ano_venda === undefined) {
        throw new Error(`cabeçalho inesperado: ${linha.slice(0, 200)}`);
      }
      continue;
    }
    const c = linha.split(CSV_SEPARADOR);
    const g = (n) => (col[n] === undefined ? null : limpar(c[col[n]]));
    yield {
      ano: g('nu_ano_venda'),
      mes: g('nu_mes_venda'),
      uf: (g('sg_uf_venda') || '').toUpperCase() || null,
      mun: g('no_municipio_venda'),
      pa: g('ds_principio_ativo'),
      apr: g('ds_descricao_apresentacao'),
      qtdBruta: g('qtd_vendida') ?? g('qt_vendida'),
      cid: g('co_cid10'),
      sexoBruto: g('sg_sexo'),
      idadeBruta: g('nu_idade'),
      unidIdade: g('nu_unidade_idade'),
      rec: g('tp_receituario')
    };
  }
}

// ---------------------------------------------------------------------------
// Carga de um arquivo
// ---------------------------------------------------------------------------
async function resolverDimensoes(client, caminho) {
  const muns = new Set();
  const meds = new Set();
  for await (const r of lerRegistros(caminho)) {
    if (r.mun && r.uf && UFS.has(r.uf)) muns.add(r.mun + SEP + r.uf);
    if (r.pa && r.apr) meds.add(r.pa + SEP + r.apr);
  }

  const novosMun = [...muns].filter((k) => !cacheMunicipio.has(k));
  for (let i = 0; i < novosMun.length; i += 5000) {
    const parte = novosMun.slice(i, i + 5000).map((k) => k.split(SEP));
    await client.query(
      `INSERT INTO municipio (nome_municipio, sigla_uf)
       SELECT * FROM unnest($1::text[], $2::text[])
       ON CONFLICT (nome_municipio, sigla_uf) DO NOTHING`,
      [parte.map((p) => p[0]), parte.map((p) => p[1])]
    );
  }
  if (novosMun.length) await recarregarCacheMunicipio(client);

  const novosMed = [...meds].filter((k) => !cacheMedicamento.has(k));
  for (let i = 0; i < novosMed.length; i += 5000) {
    const parte = novosMed.slice(i, i + 5000).map((k) => k.split(SEP));
    await client.query(
      `INSERT INTO medicamento (principio_ativo, descricao_apresentacao)
       SELECT * FROM unnest($1::text[], $2::text[])
       ON CONFLICT (principio_ativo, descricao_apresentacao) DO NOTHING`,
      [parte.map((p) => p[0]), parte.map((p) => p[1])]
    );
  }
  if (novosMed.length) await recarregarCacheMedicamento(client);

  console.log(`      dimensões: +${novosMun.length} municípios, +${novosMed.length} medicamentos`);
}

async function carregarArquivo(client, caminho) {
  const arq = path.basename(caminho);
  let lidas = 0;
  let inseridas = 0;
  let cidForaCatalogo = 0;
  const motivos = {};
  const rejeitar = (m) => { motivos[m] = (motivos[m] || 0) + 1; };

  console.log(`  [→] ${arq}: passada 1 (dimensões)`);
  await resolverDimensoes(client, caminho);

  console.log(`  [→] ${arq}: passada 2 (COPY)`);

  async function* lotes() {
    let buf = [];
    for await (const r of lerRegistros(caminho)) {
      lidas++;

      const mes2 = (r.mes || '').padStart(2, '0');
      const idPeriodo = cachePeriodo.get(`${r.ano}${mes2}`);
      if (!idPeriodo) { rejeitar('periodo_fora_do_recorte'); continue; }
      if (!r.uf || !UFS.has(r.uf)) { rejeitar('uf_invalida'); continue; }
      if (!r.mun) { rejeitar('sem_municipio'); continue; }
      if (!r.pa) { rejeitar('sem_principio_ativo'); continue; }
      if (!r.apr) { rejeitar('sem_apresentacao'); continue; }

      const qtd = Number((r.qtdBruta || '').replace(',', '.'));
      if (!Number.isFinite(qtd) || qtd <= 0) { rejeitar('quantidade_invalida'); continue; }

      const idMun = cacheMunicipio.get(r.mun + SEP + r.uf);
      const idMed = cacheMedicamento.get(r.pa + SEP + r.apr);
      if (!idMun || !idMed) { rejeitar('dimensao_nao_resolvida'); continue; }

      // CID-10: normaliza e só aceita o que existe no catálogo (FK)
      let cid = r.cid ? r.cid.toUpperCase().replace(/[.\s]/g, '') : null;
      if (cid && (!catalogoCid || !catalogoCid.has(cid))) {
        if (catalogoCid) cidForaCatalogo++;
        cid = null;
      }

      // Sexo: 1 -> M, 2 -> F
      const sexo = SEXO[r.sexoBruto] || null;

      // Idade gravada em ANOS. Unidade 1 = anos, 2 = meses. Sem unidade => NULL.
      let idade = null;
      const n = parseInt(r.idadeBruta, 10);
      if (Number.isFinite(n) && n >= 0) {
        if (r.unidIdade === '1') idade = n;
        else if (r.unidIdade === '2') idade = Math.floor(n / 12);
        if (idade !== null && idade > 130) idade = null;
      }

      // Antimicrobiano: receituário 5 (dicionário 2026) ou qualquer campo exclusivo preenchido
      const ehAntimicrobiano = r.rec === '5' || !!(r.cid || r.sexoBruto || r.idadeBruta);

      buf.push([
        idPeriodo, `${r.ano}-${mes2}-01`, idMun, idMed, qtd,
        ehAntimicrobiano ? 't' : 'f', cid, sexo, idade, arq
      ].map(esc).join('\t'));
      inseridas++;

      if (buf.length >= LOTE_COPY) { yield buf.join('\n') + '\n'; buf = []; }
    }
    if (buf.length) yield buf.join('\n') + '\n';
  }

  await client.query('BEGIN');
  try {
    await pipeline(
      Readable.from(lotes()),
      client.query(copyFrom(
        `COPY venda_medicamento
           (id_periodo, data_venda, id_municipio, id_medicamento, quantidade_vendida,
            eh_antimicrobiano, codigo_cid10, sexo_paciente, idade_paciente, arquivo_origem)
         FROM STDIN WITH (FORMAT text)`))
    );
    const rejeitadas = lidas - inseridas;
    await client.query(
      `INSERT INTO carga_arquivo (arquivo, linhas_lidas, linhas_inseridas, linhas_rejeitadas, motivos_rejeicao)
       VALUES ($1,$2,$3,$4,$5)`,
      [arq, lidas, inseridas, rejeitadas, JSON.stringify(motivos)]
    );
    await client.query('COMMIT');
    console.log(`      ✓ ${inseridas} inseridas | ✗ ${rejeitadas} rejeitadas`
      + (rejeitadas ? ` ${JSON.stringify(motivos)}` : '')
      + (cidForaCatalogo ? ` | CID fora do catálogo (→NULL): ${cidForaCatalogo}` : ''));
    return inseridas;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const inicio = Date.now();
  console.log(`FarmaData — carga SNGPC (ano ${ANO})\n`);
  fs.mkdirSync(TMP_DIR, { recursive: true });

  const client = new Client({
    connectionString: process.env.DATABASE_URL || 'postgres://postgres:postgres@localhost:5432/farmadata'
  });
  await client.connect();
  console.log('[OK] Conectado ao PostgreSQL.');

  await garantirCargaArquivo(client);
  await garantirPeriodos(client, ANO);
  await recarregarCacheMunicipio(client);
  await recarregarCacheMedicamento(client);
  await carregarCatalogoCid(client);

  const jaCarregados = new Set(
    (await client.query('SELECT arquivo FROM carga_arquivo')).rows.map((r) => r.arquivo));
  const nome = (mes) => `EDA_Industrializados_${ANO}${mes}.csv`;
  const pendentes = MESES.filter((m) => !jaCarregados.has(nome(m)));

  if (pendentes.length) await removerIndices(client);

  const faltando = [];
  const falhas = [];
  let total = 0;

  try {
    for (const mes of MESES) {
      const arq = nome(mes);
      console.log(`\n── ${ANO}${mes} ──`);
      if (jaCarregados.has(arq)) {
        console.log('  [SKIP] já carregado (carga_arquivo).');
        continue;
      }

      const destino = path.join(TMP_DIR, arq);
      const legado = path.join(TMP_DIR, `controlados_${ANO}${mes}.csv`); // nome usado antes
      if (!fs.existsSync(destino) && fs.existsSync(legado)) fs.renameSync(legado, destino);

      if (!fs.existsSync(destino) || fs.statSync(destino).size === 0) {
        console.log('  [↓] baixando...');
        try {
          await baixarComRetry(`${BASE_URL}/${arq}`, destino);
        } catch (err) {
          console.warn(`  [ERRO] download falhou: ${err.message}`);
          faltando.push(arq);
          continue;
        }
      } else {
        console.log('  [CACHE] arquivo local encontrado.');
      }

      const t0 = Date.now();
      try {
        total += await carregarArquivo(client, destino);
        console.log(`  [OK] ${arq} em ${fmtSeg(Date.now() - t0)}`);
      } catch (err) {
        console.error(`  [ERRO] ${arq}: ${err.message}`);
        falhas.push(arq);
      }
    }
  } finally {
    await criarIndices(client);
  }

  const r = await client.query(
    'SELECT count(*) AS arquivos, coalesce(sum(linhas_inseridas),0) AS linhas FROM carga_arquivo');
  await client.end();

  console.log('\n══════════════════════════════════════════════');
  console.log(` Inseridas nesta execução: ${total.toLocaleString('pt-BR')}`);
  console.log(` Total no banco: ${Number(r.rows[0].linhas).toLocaleString('pt-BR')} linhas em ${r.rows[0].arquivos} arquivos`);
  console.log(` Tempo: ${fmtSeg(Date.now() - inicio)}`);
  if (faltando.length) console.log(` Sem download: ${faltando.join(', ')}`);
  if (falhas.length) console.log(` Falharam na carga: ${falhas.join(', ')}`);
  console.log('══════════════════════════════════════════════');

  if (faltando.length || falhas.length) process.exit(1);
}

main().catch((err) => {
  console.error('\n[ERRO CRÍTICO]:', err.message);
  process.exit(1);
});