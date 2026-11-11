# Suíte de qualidade dos dados

A suíte `tests/qualidade_dados.sql` roda em PostgreSQL por meio do alvo `make test-qualidade`.
Ela falha com código diferente de zero e grava a saída em
[`evidencias/qualidade_dados.txt`](evidencias/qualidade_dados.txt).

## Cobertura

- Unicidade e ausência de nulos em todas as chaves primárias, conferindo constraints e
  índices únicos válidos no catálogo do PostgreSQL; isso evita agrupar dezenas de milhões
  de chaves que o banco já impede de duplicar.
- Integridade referencial de todas as chaves estrangeiras declaradas, exigindo constraints
  validadas, e consistência das surrogate keys calculadas nas dimensões-view.
- Domínios de quantidade, idade, sexo, campos de antimicrobianos, regiões, receituário,
  calendário, população e clima, além da rejeição de datas/anos futuros.
- Volume mínimo de vendas (padrão: 1.000.000 linhas; configurável por `MIN_VENDAS`).
- Série mensal nacional de `venda_medicamento`: marca variações absolutas de pelo menos
  40% contra a mediana dos meses do recorte. A mediana reduz a influência de um mês extremo,
  e o limite relativo funciona também em séries curtas, onde o z-score pode nunca superar 3.
  O teste exige ao menos seis meses e inclui um cenário negativo que reduz um mês em 50%;
  esse cenário usa a mesma função temporária que avalia a série real. O limite é uma regra
  de triagem para quedas/saltos grandes e deve ser recalibrado se o recorte incluir
  sazonalidade legítima acima de 40%.
- Igualdade de contagem entre a origem e a fato dimensional quando a origem tem dados.
  Os totais mensais, regras de linha, volume e série estatística são calculados em duas
  agregações (uma por origem e outra por fato) para evitar repetir varreduras completas.

O workflow `.github/workflows/qualidade-dados.yml` inicializa o schema, insere doze linhas
sintéticas em doze meses, atualiza a dimensão e executa a suíte com `MIN_VENDAS=12`.
Essa massa valida o funcionamento das asserções no CI; a homologação do limite de volume
de produção deve usar o valor padrão ou o limite acordado para o recorte carregado.

## Execução

Com o serviço `db` ativo e as tabelas/fato carregadas:

```bash
make test-qualidade
```

Para uma carga ou fixture menor:

```bash
make test-qualidade MIN_VENDAS=12
```

O log é atualizado a cada execução. A automação do GitHub Actions também o publica como
artefato `evidencia-qualidade-dados` para cada execução do workflow.
