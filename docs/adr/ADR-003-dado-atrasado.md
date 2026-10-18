# ADR-003 — Dado atrasado e janela da dispensação (Issue #8)

**Status:** Proposto
**Data:** 2026-10-18  
**Squad:** FarmaData (UnB — Sistemas de Bancos de Dados 2)

---

## 1. Caracterizar a carga

| Dimensão | Caracterização |
|----------|----------------|
| **Domínio** | Dispensação mensal do SNGPC/Anvisa. Cada CSV `EDA_Industrializados_AAAAMM.csv` é a publicação de um mês. |
| **Tempo do evento** | `nu_ano_venda` e `nu_mes_venda` na linha. Não há dia nem hora na carga. `data_venda` é o dia 1 desse mês. |
| **Tempo de chegada** | O mês embutido no nome do arquivo, e o momento em que a carga roda. |
| **Janela analítica** | `periodo.id_periodo` (`YYYYMM`). As consultas agregam por esse mês. |
| **Atraso que importa** | A venda de um mês aparece num arquivo de outro mês. Alguns dias de atraso dentro do mesmo mês não mudam a janela, porque a granularidade publicada é o mês. |

---

## 2. Definir o problema

Uma linha pode trazer `nu_ano_venda`/`nu_mes_venda` diferente do mês codificado no nome do CSV, ou um mês ausente de `ANO_RECORTE`. A carga precisa definir o `id_periodo` gravado e o registro deixado em `carga_arquivo`.

---

## 3. Alternativas consideradas

| Alternativa | Descrição |
|-------------|-----------|
| **A — Janela = mês do arquivo** | A linha entra no período do CSV que a trouxe. |
| **B — Descartar fora de ordem** | Só entra linha cujo mês da venda é o mês do arquivo. O resto é rejeitado com log. |
| **C — Realocar para o mês da venda** *(escolhida)* | Dentro do recorte, a linha entra no período da dispensação e o desvio fica registrado. Fora do recorte, é descartada com log. |
| **D — Watermark de alguns dias** | Segurar a janela aberta por N dias, como num fluxo contínuo. |

---

## 4. Avaliação

**A** agrega pelo mês da publicação. Consultas por `id_periodo` passam a medir o arquivo, não a dispensação.

**B** mantém o mês do arquivo homogêneo. A dispensação de outro mês não entra na fato; a rejeição fica em `motivos_rejeicao`.

**C** grava `id_periodo` e `data_venda` pelo mês da venda. `arquivo_origem` identifica o CSV. `carga_arquivo.eventos_atrasados` guarda a contagem de linhas nesse caso, inclusive zero.

**D** exige timestamp diário e janela deslizante. O CSV publicado tem ano e mês; `periodo` materializa os doze meses de `ANO_RECORTE`.

---

## 5. Decisão

**Alternativa C.**

1. **A janela correta é o mês da venda** (`nu_ano_venda`, `nu_mes_venda`), não o mês do arquivo e não a data da carga.
2. **Mês da venda dentro do recorte, diferente do arquivo:** a linha é inserida nesse período. `id_periodo` e `data_venda` recebem o mês da venda. `arquivo_origem` recebe o nome do CSV. A contagem vai para `carga_arquivo.eventos_atrasados` (`realocado_para_periodo_da_venda` e `por_periodo_da_venda`). O mesmo vale quando o mês da venda é anterior ou posterior ao mês do arquivo.
3. **Mês da venda fora do recorte:** a linha não é inserida. O motivo `periodo_fora_do_recorte` entra em `carga_arquivo.motivos_rejeicao`. Nenhum período é criado fora de `ANO_RECORTE`.
4. **Dias dentro do mesmo mês:** `id_periodo` não muda. A carga não lê dia; o mês da venda já é a janela.

O reprocessamento do CSV é `DELETE` das linhas daquele `arquivo_origem` seguido de `COPY`, na mesma transação.

---

## 6. Consequências

**Permite:**

- Agregação por `id_periodo` no mês em que o medicamento foi dispensado.
- Ver, por arquivo, quantas linhas foram realocadas e para quais períodos, mesmo quando a contagem é zero.
- Ver, por arquivo, quantas linhas foram descartadas por caírem fora do ano.

**Impede:**

- Distinguir atraso de dias dentro do mesmo mês: a carga não possui coluna de dia.
- Inserir linha cujo mês da venda está fora de `ANO_RECORTE`.

**Onde está no código:** `scripts/carregar_sngpc.js`, na passada de `COPY` de cada CSV.
