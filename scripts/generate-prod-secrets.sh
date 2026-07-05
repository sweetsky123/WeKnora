#!/usr/bin/env bash
set -euo pipefail

# Generate production secrets and replace matching KEY=value lines in .env.
# Safe defaults:
# - Only updates an existing .env (will not create one implicitly)
# - Creates a timestamped backup before modifying
# - Uses URL/sed-safe character sets for passwords and API keys
# - Preserves file permissions as much as possible

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${PROJECT_ROOT}/.env}"
BACKUP_FILE="${ENV_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: .env file not found: ${ENV_FILE}" >&2
  echo "Usage: $0 [/absolute/or/relative/path/to/.env]" >&2
  exit 1
fi

cp "${ENV_FILE}" "${BACKUP_FILE}"
chmod 600 "${BACKUP_FILE}" 2>/dev/null || true

rand_alnum() (
  set +o pipefail
  local n="$1"
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${n}"
)

rand_hex() (
  local bytes="$1"
  openssl rand -hex "${bytes}"
)

replace_or_append() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${ENV_FILE}"
  fi
}

# Core runtime secrets
DB_PASSWORD="$(rand_alnum 32)"
REDIS_PASSWORD="$(rand_alnum 32)"
JWT_SECRET="$(rand_hex 32)"
SYSTEM_AES_KEY="$(rand_alnum 32)"
TENANT_AES_KEY="$(rand_alnum 32)"
NEO4J_PASSWORD="$(rand_alnum 32)"

# Langfuse runtime secrets
LANGFUSE_CLICKHOUSE_PASSWORD="$(rand_alnum 32)"
LANGFUSE_MINIO_PASSWORD="$(rand_alnum 32)"
LANGFUSE_SALT="$(rand_alnum 48)"
LANGFUSE_ENCRYPTION_KEY="$(rand_hex 32)"
LANGFUSE_NEXTAUTH_SECRET="$(rand_alnum 48)"
LANGFUSE_INIT_USER_PASSWORD="$(rand_alnum 32)"

# Langfuse API keys and bootstrap IDs
LANGFUSE_PUBLIC_KEY="pk-lf-$(rand_alnum 24)"
LANGFUSE_SECRET_KEY="sk-lf-$(rand_alnum 48)"

replace_or_append "DB_PASSWORD" "${DB_PASSWORD}"
replace_or_append "REDIS_PASSWORD" "${REDIS_PASSWORD}"
replace_or_append "JWT_SECRET" "${JWT_SECRET}"
replace_or_append "SYSTEM_AES_KEY" "${SYSTEM_AES_KEY}"
replace_or_append "TENANT_AES_KEY" "${TENANT_AES_KEY}"
replace_or_append "NEO4J_PASSWORD" "${NEO4J_PASSWORD}"

replace_or_append "LANGFUSE_ENABLED" "true"
replace_or_append "LANGFUSE_HOST" "http://langfuse-web:3000"
replace_or_append "LANGFUSE_DB_NAME" "langfuse"
replace_or_append "LANGFUSE_REDIS_DB" "1"
replace_or_append "LANGFUSE_CLICKHOUSE_USER" "clickhouse"
replace_or_append "LANGFUSE_CLICKHOUSE_PASSWORD" "${LANGFUSE_CLICKHOUSE_PASSWORD}"
replace_or_append "LANGFUSE_MINIO_USER" "langfuseminio"
replace_or_append "LANGFUSE_MINIO_PASSWORD" "${LANGFUSE_MINIO_PASSWORD}"
replace_or_append "LANGFUSE_SALT" "${LANGFUSE_SALT}"
replace_or_append "LANGFUSE_ENCRYPTION_KEY" "${LANGFUSE_ENCRYPTION_KEY}"
replace_or_append "LANGFUSE_NEXTAUTH_SECRET" "${LANGFUSE_NEXTAUTH_SECRET}"
replace_or_append "LANGFUSE_NEXTAUTH_URL" "http://langfuse-web:3000"
replace_or_append "LANGFUSE_TELEMETRY_ENABLED" "false"
replace_or_append "LANGFUSE_INIT_ORG_ID" "WeKnora"
replace_or_append "LANGFUSE_INIT_ORG_NAME" "WeKnora"
replace_or_append "LANGFUSE_INIT_PROJECT_ID" "WeKnora"
replace_or_append "LANGFUSE_INIT_PROJECT_NAME" "WeKnora"
replace_or_append "LANGFUSE_INIT_PROJECT_PUBLIC_KEY" "${LANGFUSE_PUBLIC_KEY}"
replace_or_append "LANGFUSE_INIT_PROJECT_SECRET_KEY" "${LANGFUSE_SECRET_KEY}"
replace_or_append "LANGFUSE_INIT_USER_EMAIL" "admin@example.com"
replace_or_append "LANGFUSE_INIT_USER_NAME" "Admin"
replace_or_append "LANGFUSE_INIT_USER_PASSWORD" "${LANGFUSE_INIT_USER_PASSWORD}"
replace_or_append "LANGFUSE_PUBLIC_KEY" "${LANGFUSE_PUBLIC_KEY}"
replace_or_append "LANGFUSE_SECRET_KEY" "${LANGFUSE_SECRET_KEY}"

chmod 600 "${ENV_FILE}" 2>/dev/null || true

cat <<EOF
Done.
Updated: ${ENV_FILE}
Backup : ${BACKUP_FILE}

Generated/rotated keys:
- DB_PASSWORD
- REDIS_PASSWORD
- JWT_SECRET
- SYSTEM_AES_KEY
- TENANT_AES_KEY
- NEO4J_PASSWORD
- LANGFUSE_CLICKHOUSE_PASSWORD
- LANGFUSE_MINIO_PASSWORD
- LANGFUSE_SALT
- LANGFUSE_ENCRYPTION_KEY
- LANGFUSE_NEXTAUTH_SECRET
- LANGFUSE_INIT_USER_PASSWORD
- LANGFUSE_INIT_PROJECT_PUBLIC_KEY
- LANGFUSE_INIT_PROJECT_SECRET_KEY
- LANGFUSE_PUBLIC_KEY
- LANGFUSE_SECRET_KEY

Notes:
- Review LANGFUSE_INIT_USER_EMAIL if you want a real mailbox.
- Run this BEFORE first production startup whenever possible.
- If postgres/redis/neo4j/langfuse already initialized with old credentials, rotating them only in .env will break connectivity; in that case rotate service-side credentials together or start from fresh volumes.
EOF
