// Etapa 7: População por faixa etária e município (IBGE/SIDRA, Censo 2022, tabela 9514)
// Uso: DATABASE_URL=postgres://... node scripts/carregar_ibge_faixa_etaria.js
//
// Roda depois de carregar_ibge_populacao.js (precisa de municipio.codigo_ibge já preenchido).
// A tabela 9514 só existe para o Censo 2022 (não varia por ANO_RECORTE), então o ano é fixo.

'use strict';

const https = require('https');
const { Client } = require('pg');

const ANO = 2022;
const SEXO_TOTAL = 6794;
// Categorias de nível 1 (faixas de 5 anos) da classificação "Idade" (id 287) da tabela 9514.
const FAIXAS = [
  [93070, '0 a 4 anos'], [93084, '5 a 9 anos'], [93085, '10 a 14 anos'], [93086, '15 a 19 anos'],
  [93087, '20 a 24 anos'], [93088, '25 a 29 anos'], [93089, '30 a 34 anos'], [93090, '35 a 39 anos'],
  [93091, '40 a 44 anos'], [93092, '45 a 49 anos'], [93093, '50 a 54 anos'], [93094, '55 a 59 anos'],
  [93095, '60 a 64 anos'], [93096, '65 a 69 anos'], [93097, '70 a 74 anos'], [93098, '75 a 79 anos'],
  [49108, '80 a 84 anos'], [49109, '85 a 89 anos'], [60040, '90 a 94 anos'], [60041, '95 a 99 anos'],
  [6653, '100 anos ou mais']
];

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

// A API rejeita (HTTP 500) pedir todas as faixas numa única requisição — uma por faixa é o que funciona.
async function buscarFaixa(idCategoria) {
  const url = `https://servicodados.ibge.gov.br/api/v3/agregados/9514/periodos/${ANO}/variaveis/93` +
    `?localidades=N6%5Ball%5D&classificacao=2%5B${SEXO_TOTAL}%5D%7C287%5B${idCategoria}%5D`;
  const resp = await buscarJSON(url);
  const serie = resp?.[0]?.resultados?.[0]?.series || [];
  const porCodigo = new Map();
  for (const s of serie) {
    // Faixas pequenas em municípios pequenos vêm como "X" (sigilo estatístico do IBGE), não número.
    const pop = parseInt(s.serie?.[String(ANO)], 10);
    if (Number.isFinite(pop)) porCodigo.set(parseInt(s.localidade.id, 10), pop);
  }
  return porCodigo;
}

async function main() {
  console.log(`===> Buscando população por faixa etária (IBGE/Censo ${ANO})...`);

  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    const { rows: municipios } = await client.query(
      'SELECT id_municipio, codigo_ibge FROM municipio WHERE codigo_ibge IS NOT NULL'
    );
    const idPorCodigo = new Map(municipios.map((m) => [m.codigo_ibge, m.id_municipio]));
    console.log(`[OK] ${idPorCodigo.size} municípios com codigo_ibge disponíveis para cruzar.`);

    let totalInseridas = 0;
    for (const [idCategoria, nomeFaixa] of FAIXAS) {
      const porCodigo = await buscarFaixa(idCategoria);
      const linhas = [];
      for (const [codigo, pop] of porCodigo) {
        const idMunicipio = idPorCodigo.get(codigo);
        if (idMunicipio !== undefined) linhas.push([idMunicipio, pop]);
      }

      for (let i = 0; i < linhas.length; i += 2000) {
        const parte = linhas.slice(i, i + 2000);
        await client.query(
          `INSERT INTO ibge_populacao_faixa_etaria_municipio (id_municipio, ano, faixa_etaria, populacao)
           SELECT id_municipio, $3, $4, populacao FROM unnest($1::int[], $2::int[]) AS v(id_municipio, populacao)
           ON CONFLICT (id_municipio, ano, faixa_etaria) DO UPDATE SET populacao = EXCLUDED.populacao`,
          [parte.map((p) => p[0]), parte.map((p) => p[1]), ANO, nomeFaixa]
        );
      }
      totalInseridas += linhas.length;
      console.log(`[OK] "${nomeFaixa}": ${linhas.length} municípios gravados.`);
    }
    console.log(`[SUCESSO] ${totalInseridas} registros gravados em ibge_populacao_faixa_etaria_municipio (Censo ${ANO}).`);
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error('[ERRO CRÍTICO]:', err);
  process.exit(1);
});
