# Airflow 2.10 + Node.js 20 (a extração reaproveita scripts/carregar_sngpc.js).
# Build a partir da raiz do repositório (precisa de package.json):
#   docker compose -f docker-compose.yml -f docker-compose.airflow.yml build airflow
FROM node:20-slim AS node_deps
WORKDIR /deps
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM apache/airflow:2.10.5-python3.12
USER root
COPY --from=node_deps /usr/local/bin/node /usr/local/bin/node
COPY --from=node_deps /deps/node_modules /opt/node_modules
# Fallback de resolução de módulos para o repositório montado em /opt/farmadata
ENV NODE_PATH=/opt/node_modules
USER airflow
RUN pip install --no-cache-dir "psycopg[binary]==3.2.3"
