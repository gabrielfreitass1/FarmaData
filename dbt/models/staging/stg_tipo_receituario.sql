select
    id_tipo_receituario,
    trim(codigo)    as codigo_receituario,
    trim(descricao) as descricao_receituario
from {{ source('farmadata', 'tipo_receituario') }}
