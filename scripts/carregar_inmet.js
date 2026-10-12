// Etapa 6: Clima mensal por UF (INMET — dados históricos por estação)
// Uso: DATABASE_URL=postgres://... node scripts/carregar_inmet.js
//
// Baixa o ZIP anual de dados históricos do INMET (um CSV por estação, dado horário),
// agrega por UF/mês (temperatura média, precipitação média, nº de estações) e grava
// em clima_mensal_uf. Lê o ZIP "na mão" (central directory + zlib.inflateRawSync) para
// não precisar de dependência nova — só arquivos .CSV com compressão deflate, que é o
// que o INMET publica.

'use strict';

const fs = require('fs');
const path = require('path');
const https = require('https');
const zlib = require('zlib');

const ANO = parseInt(process.env.ANO_RECORTE || '2020', 10);
const URL_ZIP = `https://portal.inmet.gov.br/uploads/dadoshistoricos/${ANO}.zip`;
const TMP_DIR = path.resolve(__dirname, '../tmp');
// O WAF do portal do INMET recusa a conexão sem um User-Agent de navegador.
const USER_AGENT = 'Mozilla/5.0 (compatible; FarmaData/1.0)';

// ---------------------------------------------------------------------------
// Download
// ---------------------------------------------------------------------------
function baixarArquivo(url, destino, redirecoes = 0) {
  return new Promise((resolve, reject) => {
    if (redirecoes > 5) return reject(new Error('redirecionamentos demais'));
    const tmp = destino + '.part';
    const req = https.get(url, { headers: { 'User-Agent': USER_AGENT } }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
        res.resume();
        return baixarArquivo(new URL(res.headers.location, url).toString(), destino, redirecoes + 1)
          .then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`HTTP ${res.statusCode} ao baixar ${url}`));
      }
      const out = fs.createWriteStream(tmp);
      res.pipe(out);
      res.on('error', (err) => { out.destroy(); reject(err); });
      out.on('error', reject);
      out.on('finish', () => { fs.renameSync(tmp, destino); resolve(); });
    });
    req.setTimeout(120000, () => req.destroy(new Error('timeout no download')));
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// Leitor de ZIP mínimo (central directory + inflate), só para .CSV em deflate/store
// ---------------------------------------------------------------------------
function listarEntradasZip(buf) {
  const EOCD_SIG = 0x06054b50;
  let eocdPos = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 65557); i--) {
    if (buf.readUInt32LE(i) === EOCD_SIG) { eocdPos = i; break; }
  }
  if (eocdPos === -1) throw new Error('fim do central directory não encontrado (ZIP inválido)');

  const entryCount = buf.readUInt16LE(eocdPos + 10);
  const cdOffset = buf.readUInt32LE(eocdPos + 16);

  const entradas = [];
  const CD_SIG = 0x02014b50;
  let pos = cdOffset;
  for (let i = 0; i < entryCount; i++) {
    if (buf.readUInt32LE(pos) !== CD_SIG) throw new Error(`central directory corrompido na entrada ${i}`);
    const method = buf.readUInt16LE(pos + 10);
    const compSize = buf.readUInt32LE(pos + 20);
    const uncompSize = buf.readUInt32LE(pos + 24);
    const nameLen = buf.readUInt16LE(pos + 28);
    const extraLen = buf.readUInt16LE(pos + 30);
    const commentLen = buf.readUInt16LE(pos + 32);
    const localOffset = buf.readUInt32LE(pos + 42);
    const name = buf.toString('utf8', pos + 46, pos + 46 + nameLen);
    entradas.push({ name, method, compSize, uncompSize, localOffset });
    pos += 46 + nameLen + extraLen + commentLen;
  }
  return entradas;
}

function extrairEntradaZip(buf, entrada) {
  const lh = entrada.localOffset;
  const lhNameLen = buf.readUInt16LE(lh + 26);
  const lhExtraLen = buf.readUInt16LE(lh + 28);
  const dataStart = lh + 30 + lhNameLen + lhExtraLen;
  const comp = buf.subarray(dataStart, dataStart + entrada.compSize);
  if (entrada.method === 0) return comp;
  if (entrada.method === 8) return zlib.inflateRawSync(comp);
  throw new Error(`método de compressão não suportado (${entrada.method}) em ${entrada.name}`);
}

// ---------------------------------------------------------------------------
// Parsing de um CSV de estação (puro — sem I/O, testável isoladamente)
// ---------------------------------------------------------------------------
function normalizarNumero(valor) {
  if (valor === undefined || valor === null) return null;
  const t = String(valor).trim();
  if (!t) return null;
  const n = parseFloat(t.replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

function acharIndiceColuna(cabecalho, trechos) {
  return cabecalho.findIndex((c) => trechos.every((t) => c.toUpperCase().includes(t)));
}

// Retorna { uf, porMes: Map(mes -> { precipSum, tempSum, tempCount }) } para o ano pedido.
function processarCsvEstacao(textoCsv, ano) {
  const linhas = textoCsv.split(/\r?\n/);
  const uf = (linhas[1].split(';')[1] || '').trim();
  const cabecalho = linhas[8].split(';');
  const idxPrecip = acharIndiceColuna(cabecalho, ['PRECIPITA']);
  const idxTemp = acharIndiceColuna(cabecalho, ['TEMPERATURA', 'BULBO SECO']);

  const porMes = new Map();
  for (let i = 9; i < linhas.length; i++) {
    const linha = linhas[i];
    if (!linha || !linha.includes(';')) continue;
    const campos = linha.split(';');
    const data = campos[0];
    if (!data) continue;
    const [anoStr, mesStr] = data.split('/');
    if (parseInt(anoStr, 10) !== ano) continue;
    const mes = parseInt(mesStr, 10);

    if (!porMes.has(mes)) porMes.set(mes, { precipSum: 0, tempSum: 0, tempCount: 0 });
    const acc = porMes.get(mes);

    const precip = normalizarNumero(campos[idxPrecip]);
    if (precip !== null && precip >= 0) acc.precipSum += precip;

    const temp = normalizarNumero(campos[idxTemp]);
    if (temp !== null && temp > -50 && temp < 60) {
      acc.tempSum += temp;
      acc.tempCount++;
    }
  }
  return { uf, porMes };
}

// Acumula o resultado de uma estação no agregador global (chave uf|id_periodo).
function acumularEstacao(acumuladorGlobal, { uf, porMes }, ano) {
  if (!uf) return;
  for (const [mes, { precipSum, tempSum, tempCount }] of porMes) {
    const chave = `${uf}|${ano * 100 + mes}`;
    if (!acumuladorGlobal.has(chave)) {
      acumuladorGlobal.set(chave, { tempSum: 0, tempQtdEstacoes: 0, precipSum: 0, precipQtdEstacoes: 0 });
    }
    const g = acumuladorGlobal.get(chave);
    if (tempCount > 0) {
      g.tempSum += tempSum / tempCount;
      g.tempQtdEstacoes++;
    }
    g.precipSum += precipSum;
    g.precipQtdEstacoes++;
  }
}

// Converte o agregador global em linhas prontas para INSERT.
function finalizarAgregados(acumuladorGlobal) {
  const linhas = [];
  for (const [chave, g] of acumuladorGlobal) {
    const [sigla_uf, idPeriodoStr] = chave.split('|');
    linhas.push({
      sigla_uf,
      id_periodo: parseInt(idPeriodoStr, 10),
      temp_media_c: g.tempQtdEstacoes ? g.tempSum / g.tempQtdEstacoes : null,
      precipitacao_media_mm: g.precipQtdEstacoes ? g.precipSum / g.precipQtdEstacoes : null,
      qtd_estacoes: Math.max(g.tempQtdEstacoes, g.precipQtdEstacoes)
    });
  }
  return linhas;
}

// ---------------------------------------------------------------------------
// Orquestração
// ---------------------------------------------------------------------------
async function main() {
  const { Client } = require('pg');
  fs.mkdirSync(TMP_DIR, { recursive: true });
  const destino = path.join(TMP_DIR, `inmet_${ANO}.zip`);

  if (!fs.existsSync(destino)) {
    console.log(`===> Baixando dados históricos do INMET (${ANO})...`);
    await baixarArquivo(URL_ZIP, destino);
  } else {
    console.log(`[OK] ${destino} já baixado, reaproveitando.`);
  }

  const buf = fs.readFileSync(destino);
  const entradas = listarEntradasZip(buf).filter((e) => e.name.toUpperCase().endsWith('.CSV'));
  console.log(`[OK] ${entradas.length} estações encontradas no ZIP de ${ANO}.`);

  const acumuladorGlobal = new Map();
  for (const entrada of entradas) {
    const texto = extrairEntradaZip(buf, entrada).toString('latin1');
    const resultado = processarCsvEstacao(texto, ANO);
    acumularEstacao(acumuladorGlobal, resultado, ANO);
  }

  const linhas = finalizarAgregados(acumuladorGlobal);
  console.log(`[OK] ${linhas.length} combinações UF/mês agregadas.`);

  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    for (let i = 0; i < linhas.length; i += 500) {
      const parte = linhas.slice(i, i + 500);
      await client.query(
        `INSERT INTO clima_mensal_uf (sigla_uf, id_periodo, temp_media_c, precipitacao_media_mm, qtd_estacoes)
         SELECT * FROM unnest($1::text[], $2::int[], $3::numeric[], $4::numeric[], $5::smallint[])
         ON CONFLICT (sigla_uf, id_periodo) DO UPDATE SET
           temp_media_c = EXCLUDED.temp_media_c,
           precipitacao_media_mm = EXCLUDED.precipitacao_media_mm,
           qtd_estacoes = EXCLUDED.qtd_estacoes`,
        [
          parte.map((l) => l.sigla_uf),
          parte.map((l) => l.id_periodo),
          parte.map((l) => l.temp_media_c),
          parte.map((l) => l.precipitacao_media_mm),
          parte.map((l) => l.qtd_estacoes)
        ]
      );
    }
    console.log(`[SUCESSO] ${linhas.length} registros gravados em clima_mensal_uf.`);
  } finally {
    await client.end();
  }
}

module.exports = { normalizarNumero, acharIndiceColuna, processarCsvEstacao, acumularEstacao, finalizarAgregados };

if (require.main === module) {
  main().catch((err) => {
    console.error('[ERRO CRÍTICO]:', err);
    process.exit(1);
  });
}
