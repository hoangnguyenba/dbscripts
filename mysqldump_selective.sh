#!/bin/bash
# =============================================================================
# mysqldump_selective.sh
# Dump a MySQL database, with option to include schema-only for specific tables
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION — edit these variables
# -----------------------------------------------------------------------------
DB_HOST="localhost"
DB_PORT="3306"
DB_USER="root"
DB_PASS=""                        # Leave empty to be prompted, or set here
DB_NAME="mydb"
OUTPUT_FILE="backup_$(date +%Y%m%d_%H%M%S).sql"

# Tables to export schema only (no data)
SCHEMA_ONLY_TABLES=(
  "logs"
  "sessions"
  "cache"
)

# Tables to skip entirely (no schema, no data)
SKIP_TABLES=(
  "tmp_data"
  "debug_info"
)

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# BUILD CONNECTION ARGS
# -----------------------------------------------------------------------------
MYSQL_ARGS=(-h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER")

if [[ -n "$DB_PASS" ]]; then
  MYSQL_ARGS+=(-p"$DB_PASS")
else
  # Prompt for password securely (no echo)
  read -rsp "Enter MySQL password for '$DB_USER': " DB_PASS
  echo
  MYSQL_ARGS+=(-p"$DB_PASS")
fi

DUMP_ARGS=("${MYSQL_ARGS[@]}")

# -----------------------------------------------------------------------------
# VALIDATE CONNECTION
# -----------------------------------------------------------------------------
log "Testing database connection..."
mysql "${MYSQL_ARGS[@]}" -e "USE $DB_NAME;" 2>/dev/null \
  || error "Cannot connect to database '$DB_NAME'. Check your credentials."
log "Connection OK."

# -----------------------------------------------------------------------------
# BUILD --ignore-table FLAGS
# Combine both skip + schema-only tables for the main dump pass
# -----------------------------------------------------------------------------
IGNORE_FLAGS=()

for tbl in "${SCHEMA_ONLY_TABLES[@]}"; do
  IGNORE_FLAGS+=(--ignore-table="$DB_NAME.$tbl")
done

for tbl in "${SKIP_TABLES[@]}"; do
  IGNORE_FLAGS+=(--ignore-table="$DB_NAME.$tbl")
done

# -----------------------------------------------------------------------------
# PASS 1: Full dump (schema + data) excluding ignored tables
# -----------------------------------------------------------------------------
log "Pass 1: Dumping full database (excluding ignored tables)..."
mysqldump "${DUMP_ARGS[@]}" \
  --single-transaction \
  --routines \
  --triggers \
  --events \
  "${IGNORE_FLAGS[@]}" \
  "$DB_NAME" \
  > "$OUTPUT_FILE"

log "Pass 1 complete."

# -----------------------------------------------------------------------------
# PASS 2: Schema-only dump for SCHEMA_ONLY_TABLES
# -----------------------------------------------------------------------------
if [[ ${#SCHEMA_ONLY_TABLES[@]} -gt 0 ]]; then
  log "Pass 2: Dumping schema-only for: ${SCHEMA_ONLY_TABLES[*]}..."

  mysqldump "${DUMP_ARGS[@]}" \
    --no-data \
    --single-transaction \
    "$DB_NAME" \
    "${SCHEMA_ONLY_TABLES[@]}" \
    >> "$OUTPUT_FILE"

  log "Pass 2 complete."
else
  warn "No schema-only tables defined. Skipping Pass 2."
fi

# -----------------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------------
SIZE=$(du -sh "$OUTPUT_FILE" | cut -f1)
log "Dump saved to: $OUTPUT_FILE ($SIZE)"

if [[ ${#SKIP_TABLES[@]} -gt 0 ]]; then
  warn "Fully skipped tables (no schema, no data): ${SKIP_TABLES[*]}"
fi

if [[ ${#SCHEMA_ONLY_TABLES[@]} -gt 0 ]]; then
  warn "Schema-only tables (no data exported): ${SCHEMA_ONLY_TABLES[*]}"
fi