select
    id_venda,
    id_periodo,
    data_venda,
    id_municipio,
    id_medicamento,
    codigo_cid10,
    categoria_cid10,
    quantidade_vendida,
    eh_antimicrobiano,
    sexo_paciente,
    idade_paciente_anos,
    faixa_etaria_paciente,
    arquivo_origem
from {{ ref('int_venda_classificada') }}
{% if is_incremental() %}
-- A recarga de um CSV apaga e regrava suas linhas com id_venda novos; o lote traz o arquivo inteiro.
where id_venda > (select coalesce(max(id_venda), 0) from {{ this }})
{% endif %}
