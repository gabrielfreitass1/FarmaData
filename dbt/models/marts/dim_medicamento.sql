select
    id_medicamento,
    principio_ativo,
    descricao_apresentacao
from {{ ref('stg_medicamento') }}
