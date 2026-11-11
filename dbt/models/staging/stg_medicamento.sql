select
    id_medicamento,
    trim(principio_ativo)           as principio_ativo,
    trim(descricao_apresentacao)    as descricao_apresentacao
from {{ source('farmadata', 'medicamento') }}
