select
    id_conselho,
    trim(sigla)     as sigla_conselho,
    trim(descricao) as descricao_conselho
from {{ source('farmadata', 'conselho_profissional') }}
