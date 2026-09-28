// Etapa 3 — Gera sql/05_carga_catalogo_cid10.sql a partir do catálogo DATASUS
// Uso: node scripts/carregar_cid10.js

const fs = require('fs');
const path = require('path');
const https = require('https');

// URLs de espelho dos arquivos oficiais do DATASUS
const URL_SUBCATEGORIAS = 'https://raw.githubusercontent.com/SidneyBissoli/cid10-br-mcp/master/data/CID-10-SUBCATEGORIAS.CSV';
const URL_CATEGORIAS = 'https://raw.githubusercontent.com/SidneyBissoli/cid10-br-mcp/master/data/CID-10-CATEGORIAS.CSV';

function baixarBuffer(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode !== 200) {
        return reject(new Error(`Falha no download de ${url}: HTTP ${res.statusCode}`));
      }
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    }).on('error', reject);
  });
}

function sanitizarTexto(txt) {
  if (!txt) return null;
  const limpo = txt.replace(/[\r\n\t]/g, ' ').replace(/'/g, "''").trim();
  return limpo.length > 0 ? limpo : null;
}

async function main() {
  console.log('===> Iniciando download do catálogo CID-10 do DATASUS...');
  
  let bufCategorias, bufSubcategorias;
  try {
    [bufCategorias, bufSubcategorias] = await Promise.all([
      baixarBuffer(URL_CATEGORIAS),
      baixarBuffer(URL_SUBCATEGORIAS)
    ]);
    console.log(`[OK] Download concluído: Categorias (${bufCategorias.length} bytes), Subcategorias (${bufSubcategorias.length} bytes)`);
  } catch (err) {
    console.error(`[ERRO] Falha ao baixar arquivos da CID-10: ${err.message}`);
    process.exit(1);
  }

  // Decodifica do padrão DATASUS (ISO-8859-1 / Windows-1252) para String UTF-8 do Node.js
  const textoCategorias = bufCategorias.toString('latin1');
  const textoSubcategorias = bufSubcategorias.toString('latin1');

  const cids = new Map();

  // 1. Processa Categorias (ex: A00, A01, J01)
  const linhasCat = textoCategorias.split('\n');
  for (let i = 1; i < linhasCat.length; i++) {
    const linha = linhasCat[i].trim();
    if (!linha) continue;
    const cols = linha.split(';');
    const cod = cols[0] ? cols[0].trim() : null;
    const desc = cols[2] ? cols[2].trim() : null;
    const descAbrev = cols[3] ? cols[3].trim() : null;
    if (cod && desc) {
      cids.set(cod, {
        codigo: cod,
        descricao: desc,
        descricao_abreviada: descAbrev,
        categoria: cod.slice(0, 3),
        restricao_sexo: null,
        causa_obito: null
      });
    }
  }

  // 2. Processa Subcategorias (ex: A000, A001, A499)
  const linhasSub = textoSubcategorias.split('\n');
  for (let i = 1; i < linhasSub.length; i++) {
    const linha = linhasSub[i].trim();
    if (!linha) continue;
    const cols = linha.split(';');
    const cod = cols[0] ? cols[0].trim() : null;
    const restrSexo = cols[2] ? cols[2].trim() : null;
    const causaObito = cols[3] ? cols[3].trim() : null;
    const desc = cols[4] ? cols[4].trim() : null;
    const descAbrev = cols[5] ? cols[5].trim() : null;
    if (cod && desc) {
      cids.set(cod, {
        codigo: cod,
        descricao: desc,
        descricao_abreviada: descAbrev,
        categoria: cod.slice(0, 3),
        restricao_sexo: restrSexo || null,
        causa_obito: causaObito || null
      });
    }
  }

  console.log(`[OK] Total de ${cids.size} códigos CID-10 estruturados em memória.`);

  // Gera arquivo SQL com inserção em lote para reprodutibilidade
  const outSqlPath = path.resolve(__dirname, '../sql/05_carga_catalogo_cid10.sql');
  const stream = fs.createWriteStream(outSqlPath, { encoding: 'utf8' });

  stream.write(`-- ============================================================================\n`);
  stream.write(`-- Carga Oficial do Catálogo CID-10 (DATASUS / OMS)\n`);
  stream.write(`-- Gerado automaticamente por scripts/carregar_cid10.js\n`);
  stream.write(`-- Total de registros: ${cids.size}\n`);
  stream.write(`-- ============================================================================\n\n`);
  stream.write(`BEGIN;\n\n`);

  const BATCH_SIZE = 500;
  let batch = [];
  let count = 0;

  for (const item of cids.values()) {
    const cod = `'${sanitizarTexto(item.codigo)}'`;
    const desc = `'${sanitizarTexto(item.descricao)}'`;
    const abrev = item.descricao_abreviada ? `'${sanitizarTexto(item.descricao_abreviada)}'` : 'NULL';
    const cat = item.categoria ? `'${sanitizarTexto(item.categoria)}'` : 'NULL';
    const sexo = item.restricao_sexo ? `'${sanitizarTexto(item.restricao_sexo)}'` : 'NULL';
    const obito = item.causa_obito ? `'${sanitizarTexto(item.causa_obito)}'` : 'NULL';

    batch.push(`(${cod}, ${desc}, ${abrev}, ${cat}, ${sexo}, ${obito})`);
    count++;

    if (batch.length >= BATCH_SIZE) {
      stream.write(`INSERT INTO cid10 (codigo, descricao, descricao_abreviada, categoria, restricao_sexo, causa_obito) VALUES\n`);
      stream.write(batch.join(',\n'));
      stream.write(`\nON CONFLICT (codigo) DO UPDATE SET descricao = EXCLUDED.descricao;\n\n`);
      batch = [];
    }
  }

  if (batch.length > 0) {
    stream.write(`INSERT INTO cid10 (codigo, descricao, descricao_abreviada, categoria, restricao_sexo, causa_obito) VALUES\n`);
    stream.write(batch.join(',\n'));
    stream.write(`\nON CONFLICT (codigo) DO UPDATE SET descricao = EXCLUDED.descricao;\n\n`);
  }

  stream.write(`COMMIT;\n`);
  stream.end();

  console.log(`[SUCESSO] Script SQL de carga gerado em: ${outSqlPath}`);
  console.log(`[SUCESSO] Registros gravados: ${count}`);
}

main().catch(err => {
  console.error('[ERRO CRÍTICO]:', err);
  process.exit(1);
});
