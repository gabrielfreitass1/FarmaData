select
    id_unidade_idade,
    trim(descricao) as descricao_unidade_idade
from {{ source('farmadata', 'unidade_idade') }}
