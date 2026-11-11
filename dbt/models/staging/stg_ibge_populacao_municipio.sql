select
    id_municipio,
    ano,
    populacao::bigint   as populacao
from {{ source('farmadata', 'ibge_populacao_municipio') }}
