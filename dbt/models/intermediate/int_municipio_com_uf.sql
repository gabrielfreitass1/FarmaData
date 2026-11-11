select
    m.id_municipio,
    m.nome_municipio,
    m.sigla_uf,
    uf.nome_uf,
    uf.regiao,
    m.codigo_ibge_municipio
from {{ ref('stg_municipio') }} m
join {{ ref('stg_unidade_federativa') }} uf
    on uf.sigla_uf = m.sigla_uf
