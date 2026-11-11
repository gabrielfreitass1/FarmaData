-- Massa sintética determinística usada exclusivamente no CI.
INSERT INTO municipio(id_municipio,nome_municipio,sigla_uf,codigo_ibge)
VALUES(999999,'Municipio Teste Qualidade','DF',5300108);
INSERT INTO medicamento(id_medicamento,principio_ativo,descricao_apresentacao)
VALUES(999999,'FARMADATA TESTE','Apresentação de teste');
SELECT aplicar_scd2_municipio();
INSERT INTO venda_medicamento(id_periodo,data_venda,id_municipio,id_medicamento,quantidade_vendida,eh_antimicrobiano,arquivo_origem)
SELECT id_periodo,data_inicio,999999,999999,mes::numeric,FALSE,'fixture-ci'
FROM periodo WHERE ano=2020 ORDER BY mes;
SELECT carregar_fato_venda_medicamento();
