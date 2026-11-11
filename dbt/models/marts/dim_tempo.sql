select
    id_periodo,
    ano,
    mes,
    nome_mes,
    trimestre,
    semestre,
    data_inicio,
    data_fim
from {{ ref('stg_periodo') }}
