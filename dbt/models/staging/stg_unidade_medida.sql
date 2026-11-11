select
    id_unidade_medida,
    trim(descricao) as descricao_unidade_medida
from {{ source('farmadata', 'unidade_medida') }}
