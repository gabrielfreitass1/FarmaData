with vendas as (
    select
        id_periodo,
        id_municipio,
        count(*)                                        as total_dispensacoes,
        count(*) filter (where eh_antimicrobiano)       as dispensacoes_antimicrobiano,
        sum(quantidade_vendida)                         as quantidade_total
    from {{ ref('int_venda_classificada') }}
    group by id_periodo, id_municipio
)

select
    v.id_periodo,
    p.ano,
    p.mes,
    v.id_municipio,
    m.sigla_uf,
    m.regiao,
    v.total_dispensacoes,
    v.dispensacoes_antimicrobiano,
    v.quantidade_total,
    pop.populacao,
    round(v.total_dispensacoes * 1000.0 / nullif(pop.populacao, 0), 2) as dispensacoes_por_mil_habitantes,
    cl.temperatura_media_c,
    cl.precipitacao_media_mm
from vendas v
join {{ ref('stg_periodo') }} p
    on p.id_periodo = v.id_periodo
join {{ ref('int_municipio_com_uf') }} m
    on m.id_municipio = v.id_municipio
left join {{ ref('stg_ibge_populacao_municipio') }} pop
    on pop.id_municipio = v.id_municipio
   and pop.ano = p.ano
left join {{ ref('stg_clima_mensal_uf') }} cl
    on cl.sigla_uf = m.sigla_uf
   and cl.id_periodo = v.id_periodo
