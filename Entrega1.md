Fonte transacional modelada e populada

O primeiro estágio do ciclo de vida: um sistema de origem OLTP real, com esquema versionado e carga reprodutível a partir de dados abertos brasileiros.

Prazo
22/09/2026

Peso
10% da nota final

Semana
Semana 7 no cronograma

Onde entregar
No repositório público da Squad, com a tag e1

Esta é a base de tudo o que vem depois. Uma fonte OLTP que não existe de verdade — populada, com volume, com esquema justificado — torna a E2 uma simulação e a E3 um exercício artificial. Invista aqui.

O que se espera
Um banco transacional que poderia estar em produção no domínio que a Squad escolheu. Isso significa esquema com chaves e restrições de integridade reais, migrações versionadas que rodam em ordem a partir de um banco vazio, e uma carga que traz o dado público para dentro sem passo manual.

O volume importa. Se a maior tabela tem 500 linhas, nenhuma transformação da E3 será não trivial e nenhum plano de execução da Semana 10 terá o que mostrar sobre o seu banco. Traga o recorte maior que couber confortavelmente — anos completos, não uma amostra.

A decisão desta Entrega
O ADR da E1 é sobre a modelagem do sistema de origem, no vocabulário do capítulo 5. As perguntas que costumam render:

A origem preserva histórico ou sobrescreve?
Um esquema CRUD destrói o valor anterior a cada UPDATE;
um esquema insert-only dá histórico de graça e cobra em volume.
Qual dos dois a sua pergunta de gestão exige?
Normalizar até onde?
Onde a desnormalização se paga, e com que evidência?
Que carimbo de tempo cada tabela guarda — hora do evento, da ingestão ou do processamento?
Confundi-los produz relatório que ninguém consegue explicar.
Aplique os seis passos. O passo 1, caracterizar a carga, é entregável desta E1: volume, taxa de escrita e leitura, padrão de acesso e latência tolerada, escritos.

Erros que se repetem
Carga que não reproduz.
O CSV foi baixado à mão e está no .gitignore.
Quem corrige não consegue rodar.
Automatize o download, ou versione o recorte se ele couber nos 5 MB.
Esquema sem restrição.
Tudo TEXT, nenhuma chave estrangeira, nenhum NOT NULL.
O banco aceita qualquer coisa e a qualidade do dado vira problema da E3, quando já é tarde.
Carga caracterizada “no olho”. “É bastante dado” não é caracterização.
Número de linhas, taxa de crescimento, quais consultas importam e que latência se tolera — sem isso, nenhum ADR do semestre terá base.
Pergunta de gestão vaga.
Se ela não cabe numa frase com sujeito e recorte, a E3 não vai ter o que responder.
Checklist de aceite
É o que a monitoria confere na correção. Item não atendido não zera a Entrega, mas pesa nos critérios de funcionamento e reprodutibilidade.

Domínio de dados abertos brasileiros escolhido, com a pergunta de gestão que a plataforma vai responder escrita em uma frase
Esquema físico versionado com migrações, executáveis do zero em ordem
Carga reprodutível: um comando popula o banco a partir da fonte pública, sem passo manual
Volume mínimo que torne a plataforma interessante — não bastam 100 linhas
Caracterização da carga de trabalho do domínio, no formato do passo 1 do Método de Decisão: volume, taxa de escrita e leitura, padrão de acesso, latência tolerada
Declaração de como a origem trata histórico: CRUD que sobrescreve ou insert-only, e o que isso permite perguntar
1 ADR sobre a escolha de modelagem do sistema de origem
README que permite a terceiro subir tudo com Docker Compose
