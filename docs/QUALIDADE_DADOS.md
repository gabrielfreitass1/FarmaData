# Suíte de qualidade dos dados

A suíte `tests/qualidade_dados.sql` roda em PostgreSQL por meio do alvo `make test-qualidade`.
Ela falha com código diferente de zero e grava a saída em
[`evidencias/qualidade_dados.txt`](evidencias/qualidade_dados.txt).

## Cobertura

- Unicidade e ausência de nulos em todas as chaves primárias declaradas no schema.
- Integridade referencial de todas as chaves estrangeiras declaradas, inclusive compostas.
- Domínios de quantidade, idade, sexo, campos de antimicrobianos, regiões, receituário,
  calendário, população e clima, além da rejeição de datas/anos futuros.
- Volume mínimo de vendas (padrão: 1.000.000 linhas; configurável por `MIN_VENDAS`).
- Série mensal nacional de `venda_medicamento`: z-score populacional por mês, com alerta
  para `|z| > 3`. A regra exige ao menos seis meses observados; com desvio padrão zero,
  os meses recebem z-score zero. O limite de três desvios é uma regra de triagem para
  variações extremas e não substitui investigação de sazonalidade ou validação clínica.
- Igualdade de contagem entre a origem e a fato dimensional quando a origem tem dados.

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
