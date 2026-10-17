# ADR-001 — Modelagem do Sistema de Origem FarmaData

**Status:** Aceito  
**Data:** 2026-09-28  
**Squad:** FarmaData (UnB — Sistemas de Bancos de Dados 2)

---

## 1. Caracterizar a carga

| Dimensão | Caracterização |
|----------|----------------|
| **Domínio** | Venda de medicamentos controlados e antimicrobianos no Brasil (SNGPC/Anvisa, 2020) |
| **Pergunta de gestão** | Quais princípios ativos, municípios e períodos concentram o maior volume de dispensações, e como esses padrões se distribuem por região e faixa etária? |
| **Volume estimado** | ~18 milhões de registros anuais (12 arquivos CSV mensais × ~1,5 milhão de linhas) |
| **Taxa de escrita** | Carga em lote mensal — sem escrita contínua em produção |
| **Taxa de leitura** | Consultas analíticas pontuais, baixa concorrência, latência tolerada de até 3 s |
| **Padrão de acesso** | Scan parcial com filtros por período, UF/município e princípio ativo; GROUP BY frequente; sem UPDATE nem DELETE |
| **Latência tolerada** | < 2 s para agregações mensais por UF; < 10 s para joins completos com CID-10 |
| **Crescimento** | Recorte de 1 ano configurável via `ANO_RECORTE` (padrão: 2020); extensão para outros anos não exige alteração de esquema |

---

## 2. Definir o problema

O sistema de origem precisa:

- Representar a granularidade do SNGPC: uma linha = uma dispensação.
- Preservar os campos exclusivos de antimicrobianos (CID-10, sexo, idade do paciente).
- Ser reprodutível: um único comando popula o banco do zero.
- Servir de base para as transformações das entregas E2 e E3 sem retrabalho.

---

## 3. Alternativas consideradas

| Alternativa | Descrição |
|-------------|-----------|
| **A — Tabela única desnormalizada** | CSV → única tabela wide com todos os campos como TEXT |
| **B — Esquema normalizado insert-only** *(escolhida)* | Estrela com dimensões separadas e tabela fato imutável |
| **C — Esquema CRUD normalizado** | Mesma estrela, com UPDATE/DELETE permitidos nas dimensões |
| **D — Particionamento por mês** | Tabela fato particionada por `id_periodo` desde o início |

---

## 4. Avaliação

**A — Desnormalizada:** simples de carregar, mas cria redundância massiva, elimina integridade referencial e inviabiliza o modelo dimensional da E3.

**B — Normalizada insert-only *(escolhida)*:** integridade referencial via FKs, dimensões pequenas e estáveis, tabela fato imutável que preserva histórico sem custo extra. O único overhead é o upsert nas dimensões durante a carga, gerenciável com cache em memória.

**C — CRUD normalizado:** UPDATEs em dimensões quebram rastreabilidade histórica. Os dados do SNGPC são publicações oficiais imutáveis — UPDATE não agrega valor.

**D — Particionamento:** o volume de 2020 (~8 GB) não justifica a complexidade adicional nesta entrega.

---

## 5. Decisão

**Alternativa B — Esquema normalizado insert-only.**

1. **O dado do SNGPC é imutável.** Cada CSV mensal é uma publicação oficial; insert-only é a representação fiel do domínio.
2. **Recorte de 1 ano configurável.** O ano é definido pela variável `ANO_RECORTE` (padrão: 2020). Os CSVs de um único ano somam ~6–8 GB; um recorte maior ultrapassaria os limites práticos do projeto semestral. O ano de 2020 é analiticamente relevante (pandemia + pico de antimicrobianos). Os períodos são gerados dinamicamente pelo script de carga, sem alteração de esquema para mudar o ano.
3. **Normalização viabiliza a E3.** Dimensões limpas são a base do modelo dimensional. Desnormalizar agora custaria refatoração completa na entrega seguinte.
4. **FKs como documentação viva.** O banco rejeita dados inválidos na inserção, eliminando erros de qualidade que apareceriam só na E3.

---

## 6. Consequências

**Permite:**
- Agregações mensais por UF, município e princípio ativo com índices já criados
- Série temporal sem pré-agregação
- Extensão para novos anos sem alterar o esquema

**Impede/dificulta:**
- Correção retroativa de registros (intencional — dado público e imutável)
- Consultas de "estado atual" de entidades (inaplicável neste domínio)

**Dívidas técnicas:**
- `codigo_ibge` em `municipio` não é populado na carga inicial; pode ser enriquecido com dados do IBGE futuramente.
- Se a Anvisa alterar o cabeçalho do CSV, `carregar_sngpc.js` precisará de ajuste.
- Métricas de volume são estimativas; atualizar com `\dt+` após a carga completa.
