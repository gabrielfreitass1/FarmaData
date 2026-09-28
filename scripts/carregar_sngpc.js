// Etapa 6 — Download e carga dos CSVs SNGPC/Anvisa
// Uso: DATABASE_URL=postgres://... node scripts/carregar_sngpc.js
// Variável ANO_RECORTE define o ano (padrão: 2020)

'use strict';

const fs   = require('fs');
const readline = require('readline');
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
        file.close(() => fs.unlinkSync(destino));
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
 *
 * Lê linha a linha (readline) em vez de fs.readFileSync: arquivos do SNGPC
 * passam de 900MB e estouram o limite de string do V8 (~512MB) se lidos
 * inteiros de uma vez.
 */
async function lerCSV(caminhoArquivo) {
  const rl = readline.createInterface({
    input: fs.createReadStream(caminhoArquivo, { encoding: CSV_ENCODING }),
    crlfDelay: Infinity
  });

  let cabecalho = null;
  const registros = [];
  for await (const linhaBruta of rl) {
    const linha = linhaBruta.trim();
    if (!linha) continue;

    if (!cabecalho) {
      cabecalho = linha.split(CSV_SEPARADOR).map(h =>
        h.trim().toLowerCase().replace(/[^a-z0-9_]/g, '_')
      );
      continue;
    }

    // Split simples + remoção de aspas envolventes (cada campo do SNGPC vem
    // como "valor"; rudimentar mas suficiente pois os campos não têm ';' interno)
    const cols = linha.split(CSV_SEPARADOR);
    const obj  = {};
    cabecalho.forEach((h, idx) => {
      obj[h] = (cols[idx] || '').trim().replace(/^"(.*)"$/, '$1').trim();
    });
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

const cachePeriodo = new Map();

/** Resolve id_periodo a partir de YYYYMM (inteiro), com cache em memória */
async function resolverPeriodo(client, yyyymm) {
  if (cachePeriodo.has(yyyymm)) return cachePeriodo.get(yyyymm);
  const res = await client.query(
    'SELECT id_periodo FROM periodo WHERE id_periodo = $1',
    [parseInt(yyyymm, 10)]
  );
  if (res.rows.length === 0) throw new Error(`Período ${yyyymm} não encontrado. Execute garantirPeriodos() antes da carga.`);
  cachePeriodo.set(yyyymm, res.rows[0].id_periodo);
  return res.rows[0].id_periodo;
}

/**
 * Garante que os 12 períodos do ano de recorte existem na tabela periodo.
 * Chamado automaticamente antes da carga dos CSVs.
 */
async function garantirPeriodos(client, ano) {
  const NOMES = ['Janeiro','Fevereiro','Março','Abril','Maio','Junho',
                 'Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'];
  for (let m = 1; m <= 12; m++) {
    const idPeriodo = ano * 100 + m;
    const dInicio  = new Date(ano, m - 1, 1);
    const dFim     = new Date(ano, m, 0);   // dia 0 do mês seguinte = último dia do mês
    const fmt      = d => d.toISOString().slice(0, 10);
    await client.query(
      `INSERT INTO periodo (id_periodo, ano, mes, nome_mes, trimestre, semestre, data_inicio, data_fim)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
       ON CONFLICT (id_periodo) DO NOTHING`,
      [
        idPeriodo, ano, m, NOMES[m - 1],
        Math.ceil(m / 3),
        m <= 6 ? 1 : 2,
        fmt(dInicio), fmt(dFim)
      ]
    );
  }
  console.log(`[OK] Períodos de ${ano} verificados/inseridos na tabela periodo.`);
}

// Cache em memória para dimensões (evita round-trips repetidos)
const cacheMunicipio   = new Map();
const cacheMedicamento = new Map();

// ---------------------------------------------------------------------------
// Carga de um arquivo CSV
// ---------------------------------------------------------------------------

/** Uma linha do CSV é válida para inserção (mesmo critério usado no INSERT) */
function linhaValida(r) {
  const ano = nvl(r['nu_ano_venda']);
  const mes = nvl(r['nu_mes_venda']);
  const yyyymm = (ano && mes) ? `${ano}${mes.padStart(2, '0')}` : null;
  const qtd = parseFloat((r['qt_vendida'] || '0').replace(',', '.')) || 0;
  return !!(yyyymm && nvl(r['sg_uf_venda']) && qtd > 0);
}

async function carregarArquivo(client, caminhoArquivo, nomeMes, ehAntimicrobiano) {
  const nomeArquivo = path.basename(caminhoArquivo);

  console.log(`  [→] Processando ${nomeArquivo} (antimicrobiano=${ehAntimicrobiano})...`);
  const registros = await lerCSV(caminhoArquivo);
  console.log(`      ${registros.length} linhas lidas.`);

  const esperados = registros.filter(linhaValida).length;
  const existentes = await client.query(
    'SELECT COUNT(*)::int AS n FROM venda_medicamento WHERE arquivo_origem = $1',
    [nomeArquivo]
  );
  const qtdExistente = existentes.rows[0].n;

  if (qtdExistente > 0 && qtdExistente === esperados) {
    console.log(`  [PULADO] ${nomeArquivo} já foi carregado por completo (${qtdExistente} registros).`);
    return 0;
  }
  if (qtdExistente > 0) {
    console.log(`  [RECARGA] ${nomeArquivo} tinha carga parcial (${qtdExistente}/${esperados}), refazendo...`);
    await client.query('DELETE FROM venda_medicamento WHERE arquivo_origem = $1', [nomeArquivo]);
  }

  let inseridos = 0;
  let erros     = 0;

  const COLUNAS = 11;

  // Processa em lotes
  for (let i = 0; i < registros.length; i += BATCH_SIZE) {
    const lote = registros.slice(i, i + BATCH_SIZE);
    const valores = [];
    const placeholders = [];
    await client.query('BEGIN');
    try {
      for (const r of lote) {
        // -------- Campos comuns --------
        // Colunas reais do SNGPC/Anvisa: NU_ANO_VENDA, NU_MES_VENDA, SG_UF_VENDA,
        // NO_MUNICIPIO_VENDA, DS_PRINCIPIO_ATIVO, DS_DESCRICAO_APRESENTACAO, QT_VENDIDA,
        // CO_CID10, SG_SEXO, NU_IDADE (exclusivos de antimicrobianos)
        const ano  = nvl(r['nu_ano_venda']);
        const mes  = nvl(r['nu_mes_venda']);
        const yyyymm = (ano && mes) ? `${ano}${mes.padStart(2, '0')}` : null;
        // Não há data diária no arquivo, só ano/mês: usa o 1º dia do mês
        const dataVenda    = yyyymm ? `${ano}-${mes.padStart(2, '0')}-01` : null;
        const nomeUf       = nvl(r['sg_uf_venda']);
        const nomeMunicipio = sanitizar(r['no_municipio_venda'] || 'NAO_INFORMADO');
        const principioAtivo = sanitizar(r['ds_principio_ativo'] || 'SEM_PRINCIPIO');
        const apresentacao   = sanitizar(r['ds_descricao_apresentacao'] || 'SEM_APRESENTACAO');
        const qtd           = parseFloat((r['qt_vendida'] || '0').replace(',', '.')) || 0;
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
        const codigoCid10   = ehAntimicrobiano ? nvl(r['co_cid10']) : null;
        const sexoPaciente  = ehAntimicrobiano ? nvl(r['sg_sexo']) : null;
        const idadePaciente = ehAntimicrobiano ? (parseInt(r['nu_idade'], 10) || null) : null;

        const base = valores.length;
        placeholders.push(
          `(${Array.from({ length: COLUNAS }, (_, k) => `$${base + k + 1}`).join(', ')})`
        );
        valores.push(
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
        );
        inseridos++;
      }

      if (placeholders.length > 0) {
        await client.query(
          `INSERT INTO venda_medicamento
             (id_periodo, data_venda, id_municipio, id_medicamento,
              quantidade_vendida, eh_antimicrobiano,
              codigo_cid10, sexo_paciente, idade_paciente,
              numero_notificacao, arquivo_origem)
           VALUES ${placeholders.join(', ')}`,
          valores
        );
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
  console.log('[OK] Conectado ao PostgreSQL.');

  await garantirPeriodos(client, ANO);

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
      // Download (pula se já existe localmente; arquivo de 0 bytes = download anterior
      // incompleto/falho, não conta como cache válido)
      if (!fs.existsSync(arq.destino) || fs.statSync(arq.destino).size === 0) {
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
