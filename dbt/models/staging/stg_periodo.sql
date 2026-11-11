select
    id_periodo,
    ano,
    mes,
    trim(nome_mes)  as nome_mes,
    trimestre,
    semestre,
    data_inicio,
    data_fim
from {{ source('farmadata', 'periodo') }}
