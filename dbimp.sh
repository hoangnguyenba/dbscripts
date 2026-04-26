#!/bin/bash
# =============================================================================
# dbimp.sh
# Import a MySQL dump file into a database.
# Automatically handles S3 downloads and gzip decompression.
#
# Usage:
#   ./dbimp.sh [OPTIONS]
#
# Options:
#   -h, --host      MySQL host           (default: localhost)
#   -P, --port      MySQL port           (default: 3306)
#   -u, --user      MySQL user           (default: root)
#   -p, --password  MySQL password       (default: prompt)
#   -d, --database    Target database name (required)
#   -i, --input       Input file — local path or s3://bucket/path/file.sql[.gz] (required)
#   -c, --create-db   Create the database if it doesn't exist
#       --help        Show this help message
#
# .env support:
#   Place a .env file in the directory where you run the script.
#   Supported keys: DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
#   CLI arguments always take priority over .env values.
#
# Notes:
#   - If -i starts with s3://, the file is downloaded automatically (aws CLI required)
#   - If the file ends with .gz, it is decompressed automatically before import
#
# Examples:
#   ./dbimp.sh -d mydb -i /backups/mydb_20260426.sql
#   ./dbimp.sh -d mydb -i /backups/mydb_20260426.sql.gz
#   ./dbimp.sh -d mydb -i s3://my-bucket/backups/mydb_20260426.sql
#   ./dbimp.sh -d mydb -i s3://my-bucket/backups/mydb_20260426.sql.gz
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Cleanup temp files on exit
TEMP_FILES=()
cleanup() {
  for f in "${TEMP_FILES[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

usage() {
  echo -e "
${CYAN}Usage:${NC}
  ./dbimp.sh [OPTIONS]

${CYAN}Options:${NC}
  -h, --host       MySQL host           (default: localhost)
  -P, --port       MySQL port           (default: 3306)
  -u, --user       MySQL user           (default: root)
  -p, --password   MySQL password       (default: prompt)
  -d, --database   Target database name ${RED}(required)${NC}
  -i, --input      Input file — local path or s3://bucket/path/file.sql[.gz] ${RED}(required)${NC}
  -c, --create-db  Create the database if it doesn't exist
      --help       Show this help message

${CYAN}.env support:${NC}
  Place a .env file in the directory where you run the script.
  Supported keys: DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
  CLI arguments always take priority over .env values.

${CYAN}Auto-detection:${NC}
  s3://...  File is downloaded from S3 before import (requires aws CLI)
  *.gz      File is decompressed with gunzip before import

${CYAN}Examples:${NC}
  ./dbimp.sh -d mydb -i /backups/mydb_20260426.sql
  ./dbimp.sh -d mydb -i /backups/mydb_20260426.sql.gz
  ./dbimp.sh -d mydb -i s3://my-bucket/backups/mydb_20260426.sql
  ./dbimp.sh -d mydb -i s3://my-bucket/backups/mydb_20260426.sql.gz
"
  exit 0
}

# -----------------------------------------------------------------------------
# STEP 1: DEFAULTS (empty sentinels so we can detect what CLI set)
# -----------------------------------------------------------------------------
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASS=""
DB_NAME=""
INPUT=""
CREATE_DB=false

# -----------------------------------------------------------------------------
# STEP 2: PARSE CLI ARGUMENTS (highest priority)
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)      DB_HOST="$2"; shift 2 ;;
    -P|--port)      DB_PORT="$2"; shift 2 ;;
    -u|--user)      DB_USER="$2"; shift 2 ;;
    -p|--password)  DB_PASS="$2"; shift 2 ;;
    -d|--database)  DB_NAME="$2"; shift 2 ;;
    -i|--input)     INPUT="$2";   shift 2 ;;
    -c|--create-db) CREATE_DB=true; shift ;;
    --help)         usage ;;
    *)              error "Unknown option: $1. Use --help for usage." ;;
  esac
done

# -----------------------------------------------------------------------------
# STEP 3: LOAD .env — only fills in values not already set by CLI args
# DB_*     → shared connection args (both scripts)
# DB_IMP_* → dbimp-specific args
#
# Supported keys:
#   DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
#   DB_IMP_INPUT
# -----------------------------------------------------------------------------
ENV_FILE="$(pwd)/.env"
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// }" ]] && continue
    value="${value%%#*}"
    value="${value//\"/}"
    value="${value//\'/}"
    value="${value## }"
    value="${value%% }"
    case "$key" in
      # Shared connection vars
      DB_HOST)      [[ -z "$DB_HOST" ]] && DB_HOST="$value" ;;
      DB_PORT)      [[ -z "$DB_PORT" ]] && DB_PORT="$value" ;;
      DB_DATABASE)  [[ -z "$DB_NAME" ]] && DB_NAME="$value" ;;
      DB_USERNAME)  [[ -z "$DB_USER" ]] && DB_USER="$value" ;;
      DB_PASSWORD)  [[ -z "$DB_PASS" ]] && DB_PASS="$value" ;;
      # dbimp-specific vars
      DB_IMP_INPUT)     [[ -z "$INPUT"      ]] && INPUT="$value"        ;;
      DB_IMP_CREATE_DB) [[ "$CREATE_DB" == false && "$value" == "true" ]] && CREATE_DB=true ;;
    esac
  done < "$ENV_FILE"
  warn ".env loaded from: $ENV_FILE"
fi

# -----------------------------------------------------------------------------
# STEP 4: APPLY FALLBACK DEFAULTS for anything still unset
# -----------------------------------------------------------------------------
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"

# -----------------------------------------------------------------------------
# VALIDATE REQUIRED ARGS
# -----------------------------------------------------------------------------
[[ -z "$DB_NAME" ]] && error "Database name is required. Use -d or --database."
[[ -z "$INPUT"   ]] && error "Input file is required. Use -i or --input."

# -----------------------------------------------------------------------------
# BUILD CONNECTION ARGS
# -----------------------------------------------------------------------------
MYSQL_ARGS=(-h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER")

if [[ -n "$DB_PASS" ]]; then
  MYSQL_ARGS+=(-p"$DB_PASS")
else
  read -rsp "Enter MySQL password for '$DB_USER'@'$DB_HOST': " DB_PASS
  echo
  MYSQL_ARGS+=(-p"$DB_PASS")
fi

# -----------------------------------------------------------------------------
# STEP 5: DOWNLOAD FROM S3 (if input is an S3 path)
# -----------------------------------------------------------------------------
LOCAL_FILE="$INPUT"

if [[ "$INPUT" =~ ^s3:// ]]; then
  [[ "$INPUT" =~ ^s3://[^/]+/.+ ]] \
    || error "Invalid S3 path: '$INPUT'. Format must be s3://bucket-name/path/to/file"
  command -v aws &>/dev/null \
    || error "aws CLI is not installed or not in PATH. Required to download from S3."

  FILENAME="$(basename "$INPUT")"
  LOCAL_FILE="$(mktemp /tmp/dbimp_XXXXXX_${FILENAME})"
  TEMP_FILES+=("$LOCAL_FILE")

  log "Downloading from S3: ${CYAN}$INPUT${NC}..."
  aws s3 cp "$INPUT" "$LOCAL_FILE" \
    || error "S3 download failed. Check your AWS credentials and the file path."
  log "Download complete."
else
  [[ -f "$LOCAL_FILE" ]] || error "Input file not found: '$LOCAL_FILE'"
fi

# -----------------------------------------------------------------------------
# STEP 6: DECOMPRESS (if file is gzipped)
# -----------------------------------------------------------------------------
SQL_FILE="$LOCAL_FILE"

if [[ "$LOCAL_FILE" == *.gz ]]; then
  log "Decompressing gzip file..."
  SQL_FILE="$(mktemp /tmp/dbimp_XXXXXX.sql)"
  TEMP_FILES+=("$SQL_FILE")
  gunzip -c "$LOCAL_FILE" > "$SQL_FILE" \
    || error "Failed to decompress file: '$LOCAL_FILE'"
  log "Decompression complete."
fi

# -----------------------------------------------------------------------------
# PRINT SUMMARY
# -----------------------------------------------------------------------------
echo ""
log "Configuration:"
echo "  Host        : $DB_HOST:$DB_PORT"
echo "  User        : $DB_USER"
echo "  Database    : $DB_NAME"
echo "  Input       : $INPUT"
if [[ "$INPUT" =~ ^s3:// ]]; then
  echo "  Source      : S3 (downloaded)"
else
  echo "  Source      : local"
fi
if [[ "$INPUT" == *.gz ]]; then
  echo "  Compressed  : yes (auto-decompressed)"
else
  echo "  Compressed  : no"
fi
echo "  Create DB   : $CREATE_DB"
echo ""

# -----------------------------------------------------------------------------
# VALIDATE CONNECTION (without database — just the server)
# -----------------------------------------------------------------------------
log "Testing database connection..."
mysql "${MYSQL_ARGS[@]}" -e "SELECT 1;" 2>/dev/null \
  || error "Cannot connect to MySQL server at '$DB_HOST:$DB_PORT'. Check your credentials."
log "Connection OK."

# -----------------------------------------------------------------------------
# CREATE DATABASE (if --create-db is set)
# -----------------------------------------------------------------------------
DB_EXISTS=$(mysql "${MYSQL_ARGS[@]}" -N -e \
  "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '$DB_NAME';" 2>/dev/null)

if [[ "$DB_EXISTS" -eq 0 ]]; then
  if [[ "$CREATE_DB" == true ]]; then
    log "Database '$DB_NAME' not found — creating..."
    mysql "${MYSQL_ARGS[@]}" -e \
      "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
      || error "Failed to create database '$DB_NAME'."
    log "Database '$DB_NAME' created."
  else
    error "Database '$DB_NAME' does not exist. Use -c or --create-db to create it automatically."
  fi
else
  log "Database '$DB_NAME' exists."
fi

# -----------------------------------------------------------------------------
# STEP 7: IMPORT
# -----------------------------------------------------------------------------
SIZE=$(du -sh "$SQL_FILE" | cut -f1)
log "Importing into '${DB_NAME}' (uncompressed size: $SIZE)..."

mysql "${MYSQL_ARGS[@]}" "$DB_NAME" < "$SQL_FILE" \
  || error "Import failed. Check the SQL file and database permissions."

# -----------------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------------
echo ""
log "Done! Successfully imported ${CYAN}$INPUT${NC} into database ${CYAN}$DB_NAME${NC}."