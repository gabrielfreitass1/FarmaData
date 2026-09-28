# ADR-001 — Modelagem do Sistema de Origem FarmaData

**Status:** Aceito  
**Data:** 2026-09-28  
**Squad:** FarmaData (UnB — Disciplina de Plataformas de Dados)

---

## 1. Caracterizar a carga (Passo 1 do Método de Decisão)

| Dimensão | Caracterização |
|----------|----------------|
| **Domínio** | Venda de medicamentos controlados e antimicrobianos no Brasil (SNGPC/Anvisa, 2020) |
| **Pergunta de gestão** | Quais princípios ativos, municípios e períodos concentram o maior volume de dispensações, e como esses padrões se distribuem por região e faixa etária? |
| **Volume estimado** | ~18 milhões de registros anuais (12 arquivos CSV mensais × ~1,5 milhão de linhas) |
| **Taxa de escrita** | Carga em lote mensal — sem escrita contínua em produção. Alta no momento da ingestão (~50 k inserções/min). |
| **Taxa de leitura** | Consultas analíticas pontuais (dashboard, relatórios), baixa concorrência, latência tolerada de até 3 segundos para agregações. |
| **Padrão de acesso** | Scan parcial com filtros por período, UF/município e princípio ativo; GROUP BY frequente; sem UPDATE nem DELETE dos dados brutos. |
| **Latência tolerada** | < 2 s para agregações mensais por UF; < 10 s para joins completos com CID-10. |
| **Crescimento** | Dados históricos fixos (2020). Possível extensão para outros anos em entregas futuras. |

---

## 2. Definir o problema (Passo 2)

O sistema de origem precisa:

- Representar fielmente a granularidade dos dados do SNGPC (uma linha = uma dispensação).
- Preservar toda a riqueza semântica do dado bruto (CID-10, sexo, idade — quando disponíveis).
- Ser reprodutível: qualquer membro da equipe deve conseguir popular o banco do zero com um único comando.
- Suportar as transformações das entregas E2 e E3 sem retrabalho de modelagem.

---

## 3. Levantar as alternativas (Passo 3)

| Alternativa | Descrição |
|-------------|-----------|
| **A — Tabela única desnormalizada** | CSV → única tabela wide com todos os campos como TEXT |
| **B — Esquema normalizado insert-only** *(escolhida)* | Estrela clássica com dimensões separadas e tabela fato imutável |
| **C — Esquema CRUD normalizado** | Mesma estrela, mas com UPDATE/DELETE permitidos nas dimensões |
| **D — Particionamento por mês** | Tabela fato particionada por `id_periodo` desde o início |

---

## 4. Avaliar as alternativas (Passo 4)

### A — Tabela única desnormalizada
- ✅ Simples de carregar (sem upsert nas dimensões)
- ❌ Redundância massiva (nome do município repetido milhões de vezes)
- ❌ Sem integridade referencial; qualquer análise exige string matching frágil
- ❌ Inviabiliza a E3 (sem dimensões = sem modelo dimensional limpo)

### B — Esquema normalizado insert-only *(escolhida)*
- ✅ Integridade referencial completa via chaves estrangeiras
- ✅ Dimensões pequenas e estáveis (UF, período, tipo de receituário são listas fixas)
- ✅ Tabela fato imutável: o histórico é preservado sem custo extra
- ✅ Cada dispensação é um fato atômico — não há atualização de estado
- ✅ Índices na fato cobrem os padrões de acesso esperados
- ⚠️ Exige upsert nas dimensões durante a carga (custo gerenciável com cache em memória)

### C — Esquema CRUD normalizado
- ✅ Flexibilidade para corrigir dados
- ❌ UPDATEs em dimensões quebram rastreabilidade (qual era o nome do município na venda de janeiro?)
- ❌ Dados do SNGPC são públicos e imutáveis; UPDATE não agrega valor

### D — Particionamento por mês
- ✅ Potencial ganho de performance para scans temporais
- ❌ Prematura: volume de 2020 (~8 GB) não justifica particionamento ainda
- ❌ Aumenta complexidade do Docker sem benefício mensurável nesta entrega

---

## 5. Decidir e justificar (Passo 5)

**Decisão: Alternativa B — Esquema normalizado insert-only.**

**Motivos determinantes:**

1. **O dado do SNGPC é naturalmente imutável.** Cada arquivo CSV mensal é uma publicação oficial; não há razão para atualizar registros depois da carga. Insert-only é a representação fiel do domínio.

2. **Recorte de 1 ano (2020) foi escolhido deliberadamente.** Os arquivos CSV de 2020 somam aproximadamente 6–8 GB comprimidos. Um recorte maior (2017–2023) ultrapassaria os limites práticos de tempo de ingestão e armazenamento de um projeto semestral. O ano de 2020 é analiticamente relevante (pandemia + pico de antimicrobianos).

3. **Normalização viabiliza a E3.** Dimensões limpas (medicamento, município, CID-10) são a base para qualquer modelo dimensional da E3. Desnormalizar agora custaria refatoração total na entrega seguinte.

4. **Integridade referencial como documentação viva.** As chaves estrangeiras tornam explícito o que a modelagem significa, e o banco rejeita dados inválidos na inserção — eliminando uma classe inteira de erros de qualidade que apareceriam apenas na E3.

---

## 6. Registrar as consequências (Passo 6)

### O que esta decisão permite
- Consultas analíticas diretas na tabela fato com `JOIN` nas dimensões
- Série temporal por princípio ativo sem pré-agregação
- Filtragem eficiente por CID-10 e perfil do paciente (antimicrobianos)
- Extensão para novos anos de dados sem alterar o esquema

### O que esta decisão impede ou dificulta
- Correção retroativa de registros (intencionalmente — os dados são públicos e devem ser tratados como imutáveis)
- Consultas que dependam de "estado atual" de uma entidade (não aplicável neste domínio)
- Adição de particionamento sem migração (pode ser feita na E2 se necessário)

### Dívidas técnicas conhecidas
- O campo `codigo_ibge` de `municipio` não é populado na carga inicial (dado não vem diretamente do SNGPC); pode ser enriquecido via JOIN com tabela IBGE em entrega futura.
- O script de carga (`carregar_sngpc.js`) mapeia nomes de colunas de forma defensiva — se a Anvisa alterar o cabeçalho do CSV, a carga precisará de ajuste.
- Métricas de volume são estimadas; os números reais devem ser atualizados após a carga completa (Etapa 7).
