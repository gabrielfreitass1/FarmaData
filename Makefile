.PHONY: up down logs ps psql carga reset

# Sobe o banco + roda a carga (build implícito, detached)
up:
	docker compose up -d --build

down:
	docker compose down

# Apaga também o volume de dados (recarrega do zero)
reset:
	docker compose down -v

logs:
	docker compose logs -f

ps:
	docker compose ps

# Console psql dentro do container do banco
psql:
	docker compose exec db psql -U $${POSTGRES_USER:-postgres} -d $${POSTGRES_DB:-farmadata}

# Reexecuta só o serviço de carga (útil após mudar ANO_RECORTE)
carga:
	docker compose up carga
