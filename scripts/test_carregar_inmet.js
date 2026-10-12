// Autoteste do parser/agregador do INMET (sem rede, sem ZIP).
// Uso: node scripts/test_carregar_inmet.js

'use strict';

const assert = require('node:assert');
const { normalizarNumero, processarCsvEstacao, acumularEstacao, finalizarAgregados } = require('./carregar_inmet');

function fixtureCsv() {
  return [
    'REGIAO:;CO',
    'UF:;DF',
    'ESTACAO:;BRASILIA',
    'CODIGO (WMO):;A001',
    'LATITUDE:;-15,789343',
    'LONGITUDE:;-47,925756',
    'ALTITUDE:;1160,96',
    'DATA DE FUNDACAO:;07/05/00',
    'Data;Hora UTC;PRECIPITAÇÃO TOTAL, HORÁRIO (mm);TEMPERATURA DO AR - BULBO SECO, HORARIA (°C);',
    '2020/01/01;0000 UTC;0;20;',
    '2020/01/01;0100 UTC;2,5;22,5;',
    '2019/12/31;2300 UTC;99;99;', // ano fora do recorte: deve ser ignorado
    '2020/02/01;0000 UTC;;19;' // precipitação ausente: não soma, mas temperatura entra
  ].join('\n');
}

assert.strictEqual(normalizarNumero('2,5'), 2.5);
assert.strictEqual(normalizarNumero(''), null);
assert.strictEqual(normalizarNumero(undefined), null);

const estacao = processarCsvEstacao(fixtureCsv(), 2020);
assert.strictEqual(estacao.uf, 'DF');
assert.deepStrictEqual([...estacao.porMes.keys()].sort(), [1, 2]);
assert.strictEqual(estacao.porMes.get(1).precipSum, 2.5);
assert.strictEqual(estacao.porMes.get(1).tempCount, 2);
assert.strictEqual(estacao.porMes.get(2).precipSum, 0);
assert.strictEqual(estacao.porMes.get(2).tempCount, 1);

const acumuladorGlobal = new Map();
acumularEstacao(acumuladorGlobal, estacao, 2020);
const linhas = finalizarAgregados(acumuladorGlobal);
const jan = linhas.find((l) => l.id_periodo === 202001);
assert.strictEqual(jan.sigla_uf, 'DF');
assert.strictEqual(jan.temp_media_c, 21.25);
assert.strictEqual(jan.precipitacao_media_mm, 2.5);
assert.strictEqual(jan.qtd_estacoes, 1);

console.log('[OK] carregar_inmet: parser e agregador passaram no autoteste.');
