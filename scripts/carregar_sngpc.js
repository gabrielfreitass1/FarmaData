#!/usr/bin/env node
/**
 * Script de Download e Carga dos Dados SNGPC (Anvisa)
 * =====================================================
 * Etapa 6 — FarmaData
 *
 * Baixa automaticamente os 12 arquivos CSV mensais de venda de medicamentos
 * controlados e antimicrobianos do Portal de Dados Abertos da Anvisa (2020),
 * decodifica de Windows-1252 (ANSI) para UTF-8 e insere os registros nas
 * tabelas do banco PostgreSQL criadas nas etapas 2 a 5.
 *
 * Execução:
 *   node scripts/carregar_sngpc.js
 *
 * Variáveis de ambiente (ou arquivo .env):
 *   DATABASE_URL  — string de conexão PostgreSQL
 *                   ex: postgres://usuario:senha@localhost:5432/farmadata
 *   ANO_RECORTE   — ano dos arquivos a baixar (padrão: 2020)
 */

'use strict';

const fs   = require('fs');
const path = require('path');
const https = require('https');
const http  = require('http');
const { Client } = require('pg');

// ---------------------------------------------------------------------------
// Configuração
// ---------------------------------------------------------------------------
const ANO = parseInt(process.env.ANO_RECORTE || '2020', 10);

/**
 * URLs dos arquivos CSV mensais de medicamentos controlados e antimicrobianos.
 * Fonte: https://dados.gov.br/dados/conjuntos-dados/venda-de-medicamentos-controlados-e-antimicrobianos---medicamentos-industrializados
 *
 * Padrão do nome do arquivo: EDA_Industrializados_YYYYMM.csv
 * Os arquivos são publicados no Portal de Dados Abertos com URLs estáveis.
 */
const BASE_URL = 'https://dados.anvisa.gov.br/dados/SNGPC/Industrializados';

const MESES = ['01','02','03','04','05','06','07','08','09','10','11','12'];

// Separador do CSV e codificação
const CSV_SEPARADOR = ';';
const CSV_ENCODING  = 'latin1'; // Windows-1252 / ANSI

// Tamanho do lote para INSERT em batch
const BATCH_SIZE = 1000;

// Diretório temporário para armazenar CSVs baixados
const TMP_DIR = path.resolve(__dirname, '../tmp');

// ---------------------------------------------------------------------------
// Utilitários
// ---------------------------------------------------------------------------

/** Garante que o diretório temporário existe */
function garantirDiretorio(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

/** Sanitiza uma string para inserção SQL segura */
function sanitizar(val) {
  if (val === undefined || val === null || val.toString().trim() === '') return null;
  return val.toString().replace(/[\r\n\t]/g, ' ').replace(/'/g, "''").trim();
}

/** Converte string vazia em null */
function nvl(val) {
  const s = (val || '').toString().trim();
  return s.length > 0 ? s : null;
}

/** Baixa uma URL e salva no disco, retorna o caminho do arquivo */
function baixarArquivo(url, destino) {
  return new Promise((resolve, reject) => {
    // Escolhe http ou https conforme a URL
    const lib = url.startsWith('https') ? https : http;
    const file = fs.createWriteStream(destino);

    lib.get(url, (res) => {
      if (res.statusCode === 301 || res.statusCode === 302) {
        // Segue redirecionamento uma vez
        file.close();
        fs.unlinkSync(destino);
        return baixarArquivo(res.headers.location, destino).then(resolve).catch(reject);
      }
      if (res.statusCode !== 200) {
        file.close();
        return reject(new Error(`HTTP ${res.statusCode} ao baixar ${url}`));
      }
      res.pipe(file);
      file.on('finish', () => file.close(resolve));
    }).on('error', (err) => {
      file.close();
      if (fs.existsSync(destino)) fs.unlinkSync(destino);
      reject(err);
    });
  });
}

// ---------------------------------------------------------------------------
// Leitura e parse do CSV
// ---------------------------------------------------------------------------

/**
 * Lê o arquivo CSV (codificado em latin1) e retorna array de objetos.
 * Lida com campos entre aspas e separador ;
 */
function lerCSV(caminhoArquivo) {
  const conteudo = fs.readFileSync(caminhoArquivo, CSV_ENCODING);
  const linhas   = conteudo.split('\n');
  if (linhas.length < 2) return [];

  // Cabeçalho: normaliza para lowercase sem espaços
  const cabecalho = linhas[0].split(CSV_SEPARADOR).map(h =>
    h.trim().toLowerCase().replace(/[^a-z0-9_]/g, '_')
  );

  const registros = [];
  for (let i = 1; i < linhas.length; i++) {
    const linha = linhas[i].trim();
    if (!linha) continue;

    // Split respeitando aspas duplas (rudimentar mas suficiente para o SNGPC)
    const cols = linha.split(CSV_SEPARADOR);
    const obj  = {};
    cabecalho.forEach((h, idx) => { obj[h] = (cols[idx] || '').trim(); });
    registros.push(obj);
  }
  return registros;
}

// ---------------------------------------------------------------------------
// Lógica de upsert nas dimensões
// ---------------------------------------------------------------------------

/** Garante que o município existe e retorna seu id */
async function upsertMunicipio(client, nome, siglaUf) {
  const res = await client.query(
    `INSERT INTO municipio (nome_municipio, sigla_uf)
     VALUES ($1, $2)
     ON CONFLICT (nome_municipio, sigla_uf) DO UPDATE SET nome_municipio = EXCLUDED.nome_municipio
     RETURNING id_municipio`,
    [nome, siglaUf]
  );
  return res.rows[0].id_municipio;
}

/** Garante que o medicamento existe e retorna seu id */
async function upsertMedicamento(client, principioAtivo, apresentacao) {
  const res = await client.query(
    `INSERT INTO medicamento (principio_ativo, descricao_apresentacao)
     VALUES ($1, $2)
     ON CONFLICT (principio_ativo, descricao_apresentacao) DO UPDATE SET principio_ativo = EXCLUDED.principio_ativo
     RETURNING id_medicamento`,
    [principioAtivo, apresentacao]
  );
  return res.rows[0].id_medicamento;
}

/** Resolve id_periodo a partir de YYYYMM */
async function resolverPeriodo(client, yyyymm) {
  const res = await client.query(
    'SELECT id_periodo FROM periodo WHERE id_periodo = $1',
    [parseInt(yyyymm, 10)]
  );
  if (res.rows.length === 0) throw new Error(`Período ${yyyymm} não encontrado na tabela periodo`);
  return res.rows[0].id_periodo;
}

// Cache em memória para dimensões (evita round-trips repetidos)
const cacheMunicipio   = new Map();
const cacheMedicamento = new Map();

// ---------------------------------------------------------------------------
// Carga de um arquivo CSV
// ---------------------------------------------------------------------------

async function carregarArquivo(client, caminhoArquivo, nomeMes, ehAntimicrobiano) {
  console.log(`  [→] Processando ${path.basename(caminhoArquivo)} (antimicrobiano=${ehAntimicrobiano})...`);
  const registros = lerCSV(caminhoArquivo);
  console.log(`      ${registros.length} linhas lidas.`);

  let inseridos = 0;
  let erros     = 0;

  // Processa em lotes
  for (let i = 0; i < registros.length; i += BATCH_SIZE) {
    const lote = registros.slice(i, i + BATCH_SIZE);
    await client.query('BEGIN');
    try {
      for (const r of lote) {
        // -------- Campos comuns --------
        const yyyymm       = nvl(r['ano_mes_competen'] || r['ano_mes'] || r['competencia']);
        const dataVenda    = nvl(r['data_venda'] || r['dt_venda']);
        const nomeUf       = nvl(r['uf_venda'] || r['uf']);
        const nomeMunicipio = sanitizar(r['municipio_venda'] || r['municipio'] || 'NAO_INFORMADO');
        const principioAtivo = sanitizar(r['principio_ativo'] || r['descricao_apresentacao'] || 'SEM_PRINCIPIO');
        const apresentacao   = sanitizar(r['descricao_apresentacao'] || r['apresentacao'] || 'SEM_APRESENTACAO');
        const qtd           = parseFloat((r['qtd_vendida'] || r['quantidade'] || '0').replace(',', '.')) || 0;
        const numNotif      = nvl(r['numero_notificacao'] || r['nr_notificacao']);

        if (!yyyymm || !nomeUf || qtd <= 0) { erros++; continue; }

        const idPeriodo = await resolverPeriodo(client, yyyymm);

        // Upsert município com cache
        const chaveMun = `${nomeMunicipio}|${nomeUf}`;
        let idMunicipio = cacheMunicipio.get(chaveMun);
        if (!idMunicipio) {
          idMunicipio = await upsertMunicipio(client, nomeMunicipio, nomeUf);
          cacheMunicipio.set(chaveMun, idMunicipio);
        }

        // Upsert medicamento com cache
        const chaveMed = `${principioAtivo}|${apresentacao}`;
        let idMedicamento = cacheMedicamento.get(chaveMed);
        if (!idMedicamento) {
          idMedicamento = await upsertMedicamento(client, principioAtivo, apresentacao);
          cacheMedicamento.set(chaveMed, idMedicamento);
        }

        // -------- Campos exclusivos de antimicrobianos --------
        const codigoCid10   = ehAntimicrobiano ? nvl(r['cid10'] || r['codigo_cid10']) : null;
        const sexoPaciente  = ehAntimicrobiano ? nvl(r['sexo_paciente'] || r['sexo']) : null;
        const idadePaciente = ehAntimicrobiano ? (parseInt(r['idade_paciente'] || r['idade'], 10) || null) : null;

        await client.query(
          `INSERT INTO venda_medicamento
             (id_periodo, data_venda, id_municipio, id_medicamento,
              quantidade_vendida, eh_antimicrobiano,
              codigo_cid10, sexo_paciente, idade_paciente,
              numero_notificacao, arquivo_origem)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
          [
            idPeriodo,
            dataVenda,
            idMunicipio,
            idMedicamento,
            qtd,
            ehAntimicrobiano,
            codigoCid10,
            sexoPaciente,
            idadePaciente,
            numNotif,
            path.basename(caminhoArquivo)
          ]
        );
        inseridos++;
      }
      await client.query('COMMIT');
    } catch (err) {
      await client.query('ROLLBACK');
      console.error(`      [ERRO no lote ${i}–${i + BATCH_SIZE}]:`, err.message);
      erros += lote.length;
    }
  }
  console.log(`      ✓ ${inseridos} inseridos | ✗ ${erros} com erro`);
  return inseridos;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  console.log('╔══════════════════════════════════════════════════════╗');
  console.log('║  FarmaData — Carga SNGPC (Anvisa)                   ║');
  console.log(`║  Ano de recorte: ${ANO}                               ║`);
  console.log('╚══════════════════════════════════════════════════════╝\n');

  garantirDiretorio(TMP_DIR);

  const dbUrl = process.env.DATABASE_URL || 'postgres://postgres:postgres@localhost:5432/farmadata';
  const client = new Client({ connectionString: dbUrl });

  await client.connect();
  console.log('[OK] Conectado ao PostgreSQL.\n');

  let totalInseridos = 0;

  for (const mes of MESES) {
    const yyyymm = `${ANO}${mes}`;
    console.log(`\n── Mês ${yyyymm} ──`);

    // Tipos de arquivo: controlados e antimicrobianos
    const arquivos = [
      {
        url: `${BASE_URL}/EDA_Industrializados_${yyyymm}.csv`,
        destino: path.join(TMP_DIR, `controlados_${yyyymm}.csv`),
        ehAntimicrobiano: false,
        label: 'Controlados'
      },
      {
        url: `${BASE_URL}/EDA_Antimicrobianos_${yyyymm}.csv`,
        destino: path.join(TMP_DIR, `antimicrobianos_${yyyymm}.csv`),
        ehAntimicrobiano: true,
        label: 'Antimicrobianos'
      }
    ];

    for (const arq of arquivos) {
      // Download (pula se já existe localmente)
      if (!fs.existsSync(arq.destino)) {
        console.log(`  [↓] Baixando ${arq.label} ${yyyymm}...`);
        try {
          await baixarArquivo(arq.url, arq.destino);
          console.log(`  [OK] Arquivo salvo em ${arq.destino}`);
        } catch (err) {
          console.warn(`  [AVISO] Falha no download de ${arq.label} ${yyyymm}: ${err.message}`);
          console.warn(`          Pulando este arquivo.`);
          continue;
        }
      } else {
        console.log(`  [CACHE] ${arq.destino} já existe, pulando download.`);
      }

      // Carga
      totalInseridos += await carregarArquivo(client, arq.destino, yyyymm, arq.ehAntimicrobiano);
    }
  }

  await client.end();

  console.log('\n╔══════════════════════════════════════════════════════╗');
  console.log(`║  Carga concluída! Total inserido: ${totalInseridos.toLocaleString('pt-BR')} registros`);
  console.log('╚══════════════════════════════════════════════════════╝');
}

main().catch(err => {
  console.error('\n[ERRO CRÍTICO]:', err.message);
  process.exit(1);
});
