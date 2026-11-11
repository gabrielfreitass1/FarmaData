select
    id_municipio,
    ano,
    trim(faixa_etaria)  as faixa_etaria_ibge,
    populacao::bigint   as populacao
from {{ source('farmadata', 'ibge_populacao_faixa_etaria_municipio') }}
