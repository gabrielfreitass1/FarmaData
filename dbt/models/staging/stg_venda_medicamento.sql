select
    id_venda,
    id_periodo,
    data_venda,
    id_municipio,
    id_medicamento,
    id_conselho,
    id_tipo_receituario,
    id_unidade_medida,
    quantidade_vendida::numeric(10, 3)              as quantidade_vendida,
    nullif(upper(trim(codigo_cid10)), '')           as codigo_cid10,
    nullif(trim(sexo_paciente), '')                 as sexo_paciente,
    idade_paciente::integer                         as idade_paciente_anos,
    id_unidade_idade,
    eh_antimicrobiano,
    nullif(trim(numero_notificacao), '')            as numero_notificacao,
    arquivo_origem
from {{ source('farmadata', 'venda_medicamento') }}
