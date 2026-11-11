select
    id_municipio,
    trim(nome_municipio)    as nome_municipio,
    trim(sigla_uf)          as sigla_uf,
    codigo_ibge             as codigo_ibge_municipio
from {{ source('farmadata', 'municipio') }}
