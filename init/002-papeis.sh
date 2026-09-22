#!/bin/sh
# Papéis de acesso ao banco da wiki. Todos são SOMENTE LEITURA.
#
# Roda sozinho na primeira inicialização (volume vazio). Como é idempotente,
# também dá para aplicar num banco que já existe:
#
#     docker compose exec db /docker-entrypoint-initdb.d/002-papeis.sh
#
# Papéis criados:
#   keeper_api     -> a API FastAPI (../keeper-wiki-bkd). SELECT só no schema gk.
#   keeper_claude  -> consultas do Claude Code pela skill `banco`. SELECT em tudo,
#                     com statement_timeout curto e poucas conexões.
#
# Quem escreve é o dono do banco ($POSTGRES_USER), usado só pela migração e pela
# importação. Nenhum dos dois papéis abaixo recebe INSERT/UPDATE/DELETE/TRUNCATE
# nem CREATE em schema nenhum.
set -e

: "${KEEPER_API_PASSWORD:?defina KEEPER_API_PASSWORD no .env}"
: "${KEEPER_CLAUDE_PASSWORD:?defina KEEPER_CLAUDE_PASSWORD no .env}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v senha_api="$KEEPER_API_PASSWORD" \
     -v senha_claude="$KEEPER_CLAUDE_PASSWORD" \
     -v banco="$POSTGRES_DB" <<'SQL'
-- ── Papel de grupo que carrega os GRANTs de leitura ───────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keeper_leitura') THEN
    CREATE ROLE keeper_leitura NOLOGIN;
  END IF;
END $$;

-- ── keeper_api: a API. Enxerga só o schema gk ────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keeper_api') THEN
    CREATE ROLE keeper_api LOGIN;
  END IF;
END $$;
ALTER ROLE keeper_api WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  INHERIT CONNECTION LIMIT 20 PASSWORD :'senha_api';
GRANT keeper_leitura TO keeper_api;

-- Segunda camada: toda transação já nasce read-only.
ALTER ROLE keeper_api SET default_transaction_read_only = on;
ALTER ROLE keeper_api SET statement_timeout = '10s';
ALTER ROLE keeper_api SET idle_in_transaction_session_timeout = '30s';

-- ── keeper_claude: consultas exploratórias do Claude Code ────────────────────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keeper_claude') THEN
    CREATE ROLE keeper_claude LOGIN;
  END IF;
END $$;
ALTER ROLE keeper_claude WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  INHERIT CONNECTION LIMIT 4 PASSWORD :'senha_claude';

-- pg_read_all_data (PG14+) dá SELECT em todas as tabelas, inclusive nas que ainda
-- não existem. É leitura e nada mais: não existe INSERT/UPDATE/DELETE junto.
GRANT pg_read_all_data TO keeper_claude;
ALTER ROLE keeper_claude SET default_transaction_read_only = on;
ALTER ROLE keeper_claude SET statement_timeout = '15s';
ALTER ROLE keeper_claude SET idle_in_transaction_session_timeout = '30s';

-- ── Travas no que os dois NÃO podem fazer ────────────────────────────────────
-- Ninguém cria objeto no public, e nem tabela temporária no banco.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE TEMPORARY ON DATABASE :"banco" FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM keeper_api, keeper_claude;
GRANT USAGE ON SCHEMA public TO keeper_leitura;
SQL

echo "papéis keeper_api e keeper_claude prontos (somente leitura)"
