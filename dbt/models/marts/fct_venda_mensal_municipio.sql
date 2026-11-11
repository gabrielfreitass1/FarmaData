select
    id_periodo,
    ano,
    mes,
    id_municipio,
    sigla_uf,
    regiao,
    total_dispensacoes,
    dispensacoes_antimicrobiano,
    quantidade_total,
    populacao,
    dispensacoes_por_mil_habitantes,
    temperatura_media_c,
    precipitacao_media_mm
from {{ ref('int_venda_mensal_municipio') }}
