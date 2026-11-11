select
    codigo_cid10,
    descricao_cid10,
    descricao_abreviada_cid10,
    categoria_cid10,
    restricao_sexo,
    eh_causa_obito
from {{ ref('stg_cid10') }}
