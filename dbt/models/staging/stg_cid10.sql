select
    upper(trim(codigo))                     as codigo_cid10,
    trim(descricao)                         as descricao_cid10,
    nullif(trim(descricao_abreviada), '')   as descricao_abreviada_cid10,
    nullif(upper(trim(categoria)), '')      as categoria_cid10,
    nullif(trim(restricao_sexo), '')        as restricao_sexo,
    case trim(causa_obito)
        when 'S' then true
        when 'N' then false
    end                                     as eh_causa_obito
from {{ source('farmadata', 'cid10') }}
