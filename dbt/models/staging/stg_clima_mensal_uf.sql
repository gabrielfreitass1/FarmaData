select
    trim(sigla_uf)                          as sigla_uf,
    id_periodo,
    temp_media_c::numeric(5, 2)             as temperatura_media_c,
    precipitacao_media_mm::numeric(10, 2)   as precipitacao_media_mm,
    qtd_estacoes::integer                   as quantidade_estacoes
from {{ source('farmadata', 'clima_mensal_uf') }}
