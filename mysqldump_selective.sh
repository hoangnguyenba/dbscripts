#!/bin/bash
# =============================================================================
# mysqldump_selective.sh
# Dump a MySQL database, with option to include schema-only for specific tables
#
# Usage:
#   ./mysqldump_selective.sh [OPTIONS]
#
# Options:
#   -h, --host        MySQL host           (default: localhost)
#   -P, --port        MySQL port           (default: 3306)
#   -u, --user        MySQL user           (default: root)
#   -p, --password    MySQL password       (default: prompt)
#   -d, --database    Database name        (required)
#   -o, --output      Output file          (default: backup_TIMESTAMP.sql)
#   -s, --schema-only Tables for schema only, comma-separated (e.g. logs,sessions,temp_%)
#   -x, --skip        Tables to skip entirely, comma-separated (e.g. tmp,debug,cache_%)
#   --help            Show this help message
#
# Note: Use % as wildcard in table names (e.g. temp_% matches temp_users, temp_logs, etc.)
#
# Examples:
#   ./mysqldump_selective.sh -d mydb
#   ./mysqldump_selective.sh -d mydb -u admin -h db.example.com
#   ./mysqldump_selective.sh -d mydb -s logs,sessions -x tmp,debug
#   ./mysqldump_selective.sh -d mydb -s "temp_%" -x "cache_%,debug_%"
#   ./mysqldump_selective.sh -d mydb -o /backups/mydb.sql -p secret
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# DEFAULTS
# -----------------------------------------------------------------------------
DB_HOST="localhost"
DB_PORT="3306"
DB_USER="root"
DB_PASS=""
DB_NAME=""
OUTPUT_FILE=""
SCHEMA_ONLY_TABLES=()
SKIP_TABLES=()

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

usage() {
  echo -e "
${CYAN}Usage:${NC}
  ./mysqldump_selective.sh [OPTIONS]

${CYAN}Options:${NC}
  -h, --host         MySQL host           (default: localhost)
  -P, --port         MySQL port           (default: 3306)
  -u, --user         MySQL user           (default: root)
  -p, --password     MySQL password       (default: prompt)
  -d, --database     Database name        ${RED}(required)${NC}
  -o, --output       Output file          (default: backup_TIMESTAMP.sql)
  -s, --schema-only  Tables for schema only, comma-separated (supports % wildcard)
  -x, --skip         Tables to skip entirely, comma-separated (supports % wildcard)
      --help         Show this help message

${CYAN}Wildcard:${NC}
  Use % to match multiple tables by pattern, e.g. temp_% matches temp_users, temp_logs, etc.

${CYAN}Examples:${NC}
  ./mysqldump_selective.sh -d mydb
  ./mysqldump_selective.sh -d mydb -u admin -h db.example.com
  ./mysqldump_selective.sh -d mydb -s logs,sessions -x tmp,debug
  ./mysqldump_selective.sh -d mydb -s "temp_%" -x "cache_%,debug_%"
  ./mysqldump_selective.sh -d mydb -o /backups/mydb.sql -p secret
"
  exit 0
}

# -----------------------------------------------------------------------------
# PARSE ARGUMENTS
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)        DB_HOST="$2";  shift 2 ;;
    -P|--port)        DB_PORT="$2";  shift 2 ;;
    -u|--user)        DB_USER="$2";  shift 2 ;;
    -p|--password)    DB_PASS="$2";  shift 2 ;;
    -d|--database)    DB_NAME="$2";  shift 2 ;;
    -o|--output)      OUTPUT_FILE="$2"; shift 2 ;;
    -s|--schema-only)
      IFS=',' read -ra SCHEMA_ONLY_TABLES <<< "$2"
      shift 2 ;;
    -x|--skip)
      IFS=',' read -ra SKIP_TABLES <<< "$2"
      shift 2 ;;
    --help)           usage ;;
    *)                error "Unknown option: $1. Use --help for usage." ;;
  esac
done

# -----------------------------------------------------------------------------
# VALIDATE REQUIRED ARGS
# -----------------------------------------------------------------------------
[[ -z "$DB_NAME" ]] && error "Database name is required. Use -d or --database.\nRun --help for usage."

# Set default output file if not provided
[[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE="backup_${DB_NAME}_$(date +%Y%m%d_%H%M%S).sql"

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
# PRINT SUMMARY
# -----------------------------------------------------------------------------
echo ""
log "Configuration:"
echo "  Host        : $DB_HOST:$DB_PORT"
echo "  User        : $DB_USER"
echo "  Database    : $DB_NAME"
echo "  Output      : $OUTPUT_FILE"
echo "  Schema-only : ${SCHEMA_ONLY_TABLES[*]:-"(none)"}"
echo "  Skip        : ${SKIP_TABLES[*]:-"(none)"}"
echo ""

# -----------------------------------------------------------------------------
# VALIDATE CONNECTION
# -----------------------------------------------------------------------------
log "Testing database connection..."
mysql "${MYSQL_ARGS[@]}" -e "USE $DB_NAME;" 2>/dev/null \
  || error "Cannot connect to database '$DB_NAME'. Check your credentials and host."
log "Connection OK."

# -----------------------------------------------------------------------------
# RESOLVE PATTERNS — expand any entry containing % into actual table names
# -----------------------------------------------------------------------------
resolve_patterns() {
  local -n input_arr=$1   # input array (passed by name)
  local -a resolved=()

  for entry in "${input_arr[@]}"; do
    if [[ "$entry" == *%* ]]; then
      # Pattern: query information_schema for matching tables
      mapfile -t matched < <(mysql "${MYSQL_ARGS[@]}" -N -e \
        "SELECT table_name FROM information_schema.tables
         WHERE table_schema = '$DB_NAME'
         AND table_name LIKE '$entry';")

      if [[ ${#matched[@]} -eq 0 ]]; then
        warn "Pattern '$entry' matched no tables — skipping."
      else
        log "Pattern '$entry' matched: ${matched[*]}"
        resolved+=("${matched[@]}")
      fi
    else
      # Exact name — use as-is
      resolved+=("$entry")
    fi
  done

  # Write resolved list back to the caller's array
  input_arr=("${resolved[@]}")
}

# -----------------------------------------------------------------------------
# BUILD --ignore-table FLAGS
# -----------------------------------------------------------------------------
log "Resolving table patterns..."
[[ ${#SCHEMA_ONLY_TABLES[@]} -gt 0 ]] && resolve_patterns SCHEMA_ONLY_TABLES
[[ ${#SKIP_TABLES[@]}        -gt 0 ]] && resolve_patterns SKIP_TABLES

IGNORE_FLAGS=()

for tbl in "${SCHEMA_ONLY_TABLES[@]}"; do
  IGNORE_FLAGS+=(--ignore-table="$DB_NAME.$tbl")
done

for tbl in "${SKIP_TABLES[@]}"; do
  IGNORE_FLAGS+=(--ignore-table="$DB_NAME.$tbl")
done

# -----------------------------------------------------------------------------
# PASS 1: Full dump (schema + data), excluding ignored tables
# -----------------------------------------------------------------------------
log "Pass 1: Dumping full database (schema + data)..."
mysqldump "${MYSQL_ARGS[@]}" \
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
  mysqldump "${MYSQL_ARGS[@]}" \
    --no-data \
    --single-transaction \
    "$DB_NAME" \
    "${SCHEMA_ONLY_TABLES[@]}" \
    >> "$OUTPUT_FILE"
  log "Pass 2 complete."
else
  warn "No schema-only tables specified. Skipping Pass 2."
fi

# -----------------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------------
SIZE=$(du -sh "$OUTPUT_FILE" | cut -f1)
echo ""
log "Done! Dump saved to: ${CYAN}$OUTPUT_FILE${NC} ($SIZE)"
[[ ${#SKIP_TABLES[@]}        -gt 0 ]] && warn "Fully skipped (no schema, no data): ${SKIP_TABLES[*]}"
[[ ${#SCHEMA_ONLY_TABLES[@]} -gt 0 ]] && warn "Schema-only exported (no data):     ${SCHEMA_ONLY_TABLES[*]}"