select
    id_municipio,
    nome_municipio,
    sigla_uf,
    nome_uf,
    regiao,
    codigo_ibge_municipio
from {{ ref('int_municipio_com_uf') }}
