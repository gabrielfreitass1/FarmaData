// Etapa 6: População estimada por município (IBGE/SIDRA)
// Uso: DATABASE_URL=postgres://... node scripts/carregar_ibge_populacao.js
//
// Roda depois de carregar_sngpc.js (precisa que `municipio` já esteja populada):
//  1. Busca a lista oficial de municípios do IBGE e preenche municipio.codigo_ibge
//     por casamento de nome normalizado + UF (o CSV da Anvisa não traz o código IBGE).
//  2. Busca a população estimada do ano de recorte (SIDRA, tabela 6579) e grava em
//     ibge_populacao_municipio para os municípios que foram casados no passo 1.

'use strict';

const https = require('https');
const { Client } = require('pg');

const ANO = parseInt(process.env.ANO_RECORTE || '2020', 10);
const URL_MUNICIPIOS = 'https://servicodados.ibge.gov.br/api/v1/localidades/municipios';
const URL_POPULACAO = `https://servicodados.ibge.gov.br/api/v3/agregados/6579/periodos/${ANO}/variaveis/9324?localidades=N6[all]`;

function buscarJSON(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`HTTP ${res.statusCode} ao buscar ${url}`));
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch (err) {
          reject(err);
        }
      });
      res.on('error', reject);
    }).on('error', reject);
  });
}

// Normaliza para casar nome do IBGE (acentuado, Title Case) com o nome do SNGPC
// (sem acento, geralmente upper case): maiúsculas, sem diacríticos, só letras/números/espaço.
function normalizar(nome) {
  return nome
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toUpperCase()
    .replace(/[^A-Z0-9 ]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

async function main() {
  console.log(`===> Buscando municípios e população estimada (IBGE, ano ${ANO})...`);
  const [municipiosIbge, populacaoResp] = await Promise.all([
    buscarJSON(URL_MUNICIPIOS),
    buscarJSON(URL_POPULACAO)
  ]);

  // nome normalizado + UF -> código IBGE
  const codigoPorNomeUf = new Map();
  for (const m of municipiosIbge) {
    // Alguns municípios não têm microrregiao preenchida na API; regiao-imediata é o caminho alternativo.
    const uf = m.microrregiao?.mesorregiao?.UF?.sigla || m['regiao-imediata']?.['regiao-intermediaria']?.UF?.sigla;
    if (!uf) continue;
    codigoPorNomeUf.set(normalizar(m.nome) + '|' + uf, m.id);
  }
  console.log(`[OK] ${codigoPorNomeUf.size} municípios do IBGE carregados.`);

  const serie = populacaoResp?.[0]?.resultados?.[0]?.series || [];
  const populacaoPorCodigo = new Map();
  for (const s of serie) {
    const pop = s.serie?.[String(ANO)];
    if (pop !== undefined) populacaoPorCodigo.set(parseInt(s.localidade.id, 10), parseInt(pop, 10));
  }
  console.log(`[OK] ${populacaoPorCodigo.size} municípios com população estimada para ${ANO}.`);

  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    const { rows } = await client.query('SELECT id_municipio, nome_municipio, sigla_uf FROM municipio');

    const atualizacoes = [];
    let semCorrespondencia = 0;
    for (const m of rows) {
      const codigo = codigoPorNomeUf.get(normalizar(m.nome_municipio) + '|' + m.sigla_uf);
      if (codigo) atualizacoes.push([m.id_municipio, codigo]);
      else semCorrespondencia++;
    }

    for (let i = 0; i < atualizacoes.length; i += 2000) {
      const parte = atualizacoes.slice(i, i + 2000);
      await client.query(
        `UPDATE municipio AS mu SET codigo_ibge = v.codigo
         FROM unnest($1::int[], $2::int[]) AS v(id_municipio, codigo)
         WHERE mu.id_municipio = v.id_municipio`,
        [parte.map((p) => p[0]), parte.map((p) => p[1])]
      );
    }
    console.log(`[OK] codigo_ibge preenchido em ${atualizacoes.length} municípios (${semCorrespondencia} sem correspondência por nome/UF).`);

    // Mais de um id_municipio pode casar com o mesmo codigo_ibge (municípios duplicados na
    // origem SNGPC) — usar Map por id_municipio evita duas linhas da mesma chave no mesmo INSERT.
    const popPorIdMunicipio = new Map();
    for (const [idMunicipio, codigo] of atualizacoes) {
      const pop = populacaoPorCodigo.get(codigo);
      if (pop !== undefined) popPorIdMunicipio.set(idMunicipio, pop);
    }
    const popRows = [...popPorIdMunicipio.entries()];

    let inseridas = 0;
    for (let i = 0; i < popRows.length; i += 2000) {
      const parte = popRows.slice(i, i + 2000);
      if (!parte.length) continue;
      await client.query(
        `INSERT INTO ibge_populacao_municipio (id_municipio, ano, populacao)
         SELECT id_municipio, $3, populacao FROM unnest($1::int[], $2::int[]) AS v(id_municipio, populacao)
         ON CONFLICT (id_municipio, ano) DO UPDATE SET populacao = EXCLUDED.populacao`,
        [parte.map((p) => p[0]), parte.map((p) => p[1]), ANO]
      );
      inseridas += parte.length;
    }
    console.log(`[SUCESSO] ${inseridas} registros de população gravados em ibge_populacao_municipio (ano ${ANO}).`);
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error('[ERRO CRÍTICO]:', err);
  process.exit(1);
});
