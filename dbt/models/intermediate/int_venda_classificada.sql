select
    v.id_venda,
    v.id_periodo,
    v.data_venda,
    v.id_municipio,
    v.id_medicamento,
    v.quantidade_vendida,
    v.eh_antimicrobiano,
    v.codigo_cid10,
    c.categoria_cid10,
    v.sexo_paciente,
    v.idade_paciente_anos,
    case
        when not v.eh_antimicrobiano or v.idade_paciente_anos is null then null
        when v.idade_paciente_anos < 12 then '0-11 (criança)'
        when v.idade_paciente_anos < 18 then '12-17 (adolescente)'
        when v.idade_paciente_anos < 60 then '18-59 (adulto)'
        else '60+ (idoso)'
    end as faixa_etaria_paciente,
    v.arquivo_origem
from {{ ref('stg_venda_medicamento') }} v
left join {{ ref('stg_cid10') }} c
    on c.codigo_cid10 = v.codigo_cid10
