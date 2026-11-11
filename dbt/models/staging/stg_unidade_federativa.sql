select
    trim(sigla)     as sigla_uf,
    codigo_ibge     as codigo_ibge_uf,
    trim(nome)      as nome_uf,
    trim(regiao)    as regiao
from {{ source('farmadata', 'unidade_federativa') }}
