#!/bin/bash
# =============================================================================
# dbexp.sh
# Dump a MySQL database, with option to include schema-only for specific tables
#
# Usage:
#   ./dbexp.sh [OPTIONS]
#
# Options:
#   -h, --host        MySQL host             (default: localhost)
#   -P, --port        MySQL port             (default: 3306)
#   -u, --user        MySQL user             (default: root)
#   -p, --password    MySQL password         (default: prompt)
#   -d, --database    Database name          (required)
#   -o, --output      Output directory — local path or s3://bucket/path
#                     (default: current directory)
#   -f, --filename    Output filename        (default: <dbname>_<timestamp>[.sql|.sql.gz])
#   -s, --schema-only Tables for schema only, comma-separated (supports % wildcard)
#   -x, --skip        Tables to skip entirely, comma-separated (supports % wildcard)
#   -z, --zip         Compress output with gzip (auto-adds .gz extension if missing)
#       --help        Show this help message
#
# .env support:
#   Place a .env file in the directory where you run the script.
#   Supported keys: DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
#   CLI arguments always take priority over .env values.
#
# Notes:
#   - Use % as wildcard in table names (e.g. temp_% matches temp_users, temp_logs, etc.)
#   - If -o is an S3 path, the aws CLI must be installed and configured
#   - -f and -o are combined: final destination = <o>/<filename>
#   - Views are automatically detected and skipped (avoids SHOW VIEW privilege errors on RDS)
#
# Examples:
#   ./dbexp.sh -d mydb
#   ./dbexp.sh -d mydb -u admin -h db.example.com
#   ./dbexp.sh -d mydb -s logs,sessions -x tmp,debug
#   ./dbexp.sh -d mydb -s "temp_%" -x "cache_%,debug_%"
#   ./dbexp.sh -d mydb -o /backups -f mydb.sql
#   ./dbexp.sh -d mydb -z -o /backups
#   ./dbexp.sh -d mydb -z -o s3://my-bucket/backups/mysql
#   ./dbexp.sh -d mydb -z -o s3://my-bucket/backups -f mydb.sql.gz
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

usage() {
  echo -e "
${CYAN}Usage:${NC}
  ./dbexp.sh [OPTIONS]

${CYAN}Options:${NC}
  -h, --host         MySQL host             (default: localhost)
  -P, --port         MySQL port             (default: 3306)
  -u, --user         MySQL user             (default: root)
  -p, --password     MySQL password         (default: prompt)
  -d, --database     Database name          ${RED}(required)${NC}
  -o, --output       Output directory — local path or s3://bucket/path
  -f, --filename     Output filename        (default: <dbname>_<timestamp>[.sql|.sql.gz])
  -s, --schema-only  Tables for schema only, comma-separated (supports % wildcard)
  -x, --skip         Tables to skip entirely, comma-separated (supports % wildcard)
  -z, --zip          Compress output with gzip (auto-adds .gz if missing)
      --help         Show this help message

${CYAN}Wildcard:${NC}
  Use % to match multiple tables by pattern.
  e.g. temp_% matches temp_users, temp_logs, etc.

${CYAN}.env support:${NC}
  Place a .env file in the directory where you run the script.
  Supported keys: DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
  CLI arguments always take priority over .env values.

${CYAN}Output path logic:${NC}
  -o /backups -f mydb.sql                   → /backups/mydb.sql
  -o s3://my-bucket/backups                 → s3://my-bucket/backups/<dbname>_<timestamp>.sql.gz
  -o s3://my-bucket/backups -f mydb.sql.gz  → s3://my-bucket/backups/mydb.sql.gz

${CYAN}Examples:${NC}
  ./dbexp.sh -d mydb
  ./dbexp.sh -d mydb -u admin -h db.example.com
  ./dbexp.sh -d mydb -s logs,sessions -x tmp,debug
  ./dbexp.sh -d mydb -s \"temp_%\" -x \"cache_%,debug_%\"
  ./dbexp.sh -d mydb -z -o /backups -f mydb.sql
  ./dbexp.sh -d mydb -z -o s3://my-bucket/backups/mysql
  ./dbexp.sh -d mydb -z -o s3://my-bucket/backups -f mydb.sql.gz
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
OUTPUT_DIR=""
OUTPUT_FILENAME=""
SCHEMA_ONLY_TABLES=()
SKIP_TABLES=()
ZIP=false

# -----------------------------------------------------------------------------
# STEP 2: PARSE CLI ARGUMENTS (highest priority)
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)        DB_HOST="$2";         shift 2 ;;
    -P|--port)        DB_PORT="$2";         shift 2 ;;
    -u|--user)        DB_USER="$2";         shift 2 ;;
    -p|--password)    DB_PASS="$2";         shift 2 ;;
    -d|--database)    DB_NAME="$2";         shift 2 ;;
    -o|--output)      OUTPUT_DIR="$2";      shift 2 ;;
    -f|--filename)    OUTPUT_FILENAME="$2"; shift 2 ;;
    -s|--schema-only)
      IFS=',' read -ra SCHEMA_ONLY_TABLES <<< "$2"; shift 2 ;;
    -x|--skip)
      IFS=',' read -ra SKIP_TABLES <<< "$2"; shift 2 ;;
    -z|--zip)         ZIP=true; shift ;;
    --help)           usage ;;
    *)                error "Unknown option: $1. Use --help for usage." ;;
  esac
done

# -----------------------------------------------------------------------------
# STEP 3: LOAD .env — only fills in values not already set by CLI args
# DB_*     → shared connection args (both scripts)
# DB_EXP_* → dbexp-specific args
#
# Supported keys:
#   DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
#   DB_EXP_OUTPUT, DB_EXP_FILENAME, DB_EXP_SCHEMA_ONLY, DB_EXP_SKIP, DB_EXP_ZIP
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
      DB_HOST)          [[ -z "$DB_HOST"  ]] && DB_HOST="$value"  ;;
      DB_PORT)          [[ -z "$DB_PORT"  ]] && DB_PORT="$value"  ;;
      DB_DATABASE)      [[ -z "$DB_NAME"  ]] && DB_NAME="$value"  ;;
      DB_USERNAME)      [[ -z "$DB_USER"  ]] && DB_USER="$value"  ;;
      DB_PASSWORD)      [[ -z "$DB_PASS"  ]] && DB_PASS="$value"  ;;
      # dbexp-specific vars
      DB_EXP_OUTPUT)    [[ -z "$OUTPUT_DIR"      ]] && OUTPUT_DIR="$value"      ;;
      DB_EXP_FILENAME)  [[ -z "$OUTPUT_FILENAME" ]] && OUTPUT_FILENAME="$value" ;;
      DB_EXP_SCHEMA_ONLY)
        [[ ${#SCHEMA_ONLY_TABLES[@]} -eq 0 ]] \
          && IFS=',' read -ra SCHEMA_ONLY_TABLES <<< "$value" ;;
      DB_EXP_SKIP)
        [[ ${#SKIP_TABLES[@]} -eq 0 ]] \
          && IFS=',' read -ra SKIP_TABLES <<< "$value" ;;
      DB_EXP_ZIP)       [[ "$ZIP" == false && "$value" == "true" ]] && ZIP=true ;;
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
# VALIDATE & RESOLVE OUTPUT PATH
# -----------------------------------------------------------------------------
[[ -z "$DB_NAME" ]] && error "Database name is required. Use -d or --database.\nRun --help for usage."

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Resolve filename — apply .gz extension logic if --zip is set
if [[ -z "$OUTPUT_FILENAME" ]]; then
  if [[ "$ZIP" == true ]]; then
    OUTPUT_FILENAME="${DB_NAME}_${TIMESTAMP}.sql.gz"
  else
    OUTPUT_FILENAME="${DB_NAME}_${TIMESTAMP}.sql"
  fi
else
  if [[ "$ZIP" == true && "$OUTPUT_FILENAME" != *.gz ]]; then
    OUTPUT_FILENAME="${OUTPUT_FILENAME}.gz"
    warn "Auto-appended .gz to filename: $OUTPUT_FILENAME"
  fi
fi

# Detect if output is S3 or local
IS_S3=false
S3_DEST=""
LOCAL_OUTPUT=""

if [[ -z "$OUTPUT_DIR" ]]; then
  LOCAL_OUTPUT="./$OUTPUT_FILENAME"

elif [[ "$OUTPUT_DIR" =~ ^s3:// ]]; then
  [[ "$OUTPUT_DIR" =~ ^s3://[^/]+ ]] \
    || error "Invalid S3 path: '$OUTPUT_DIR'. Format must be s3://bucket-name/optional/path"
  command -v aws &>/dev/null \
    || error "aws CLI is not installed or not in PATH. Required for S3 upload."
  IS_S3=true
  S3_DEST="${OUTPUT_DIR%/}/$OUTPUT_FILENAME"
  LOCAL_OUTPUT="$(mktemp /tmp/dbexp_XXXXXX)"

else
  mkdir -p "$OUTPUT_DIR"
  LOCAL_OUTPUT="${OUTPUT_DIR%/}/$OUTPUT_FILENAME"
fi

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
echo "  Filename    : $OUTPUT_FILENAME"
if [[ "$IS_S3" == true ]]; then
  echo "  Destination : $S3_DEST (S3)"
else
  echo "  Destination : $LOCAL_OUTPUT (local)"
fi
echo "  Schema-only : ${SCHEMA_ONLY_TABLES[*]:-"(none)"}"
echo "  Skip        : ${SKIP_TABLES[*]:-"(none)"}"
echo "  Compress    : $ZIP"
echo ""

# -----------------------------------------------------------------------------
# AUTO-DETECT pv
# -----------------------------------------------------------------------------
USE_PV=false
command -v pv &>/dev/null && USE_PV=true

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
  local -n input_arr=$1
  local -a resolved=()

  for entry in "${input_arr[@]}"; do
    if [[ "$entry" == *%* ]]; then
      mapfile -t matched < <(mysql "${MYSQL_ARGS[@]}" -N -e \
        "SELECT table_name FROM information_schema.tables
         WHERE table_schema = '$DB_NAME'
         AND table_type = 'BASE TABLE'
         AND table_name LIKE '$entry';" 2>/dev/null)

      if [[ ${#matched[@]} -eq 0 ]]; then
        warn "Pattern '$entry' matched no tables — skipping."
      else
        log "Pattern '$entry' matched: ${matched[*]}"
        resolved+=("${matched[@]}")
      fi
    else
      resolved+=("$entry")
    fi
  done

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
# AUTO-DETECT AND SKIP VIEWS
# Avoids "SHOW VIEW command denied" errors on RDS where the user lacks
# the SHOW VIEW privilege. Views are excluded from both dump passes.
# -----------------------------------------------------------------------------
log "Detecting views to exclude..."
mapfile -t VIEWS < <(mysql "${MYSQL_ARGS[@]}" -N -e \
  "SELECT table_name FROM information_schema.tables
   WHERE table_schema = '$DB_NAME'
   AND table_type = 'VIEW';" 2>/dev/null)

if [[ ${#VIEWS[@]} -gt 0 ]]; then
  warn "Skipping ${#VIEWS[@]} view(s): ${VIEWS[*]}"
  for v in "${VIEWS[@]}"; do
    IGNORE_FLAGS+=(--ignore-table="$DB_NAME.$v")
  done
else
  log "No views found."
fi

# -----------------------------------------------------------------------------
# DUMP — use a temp .sql file, then compress/move into final destination
# -----------------------------------------------------------------------------
TEMP_SQL="$(mktemp /tmp/dbexp_XXXXXX.sql)"

# PASS 1: Full dump (schema + data), excluding ignored tables and views
# --skip-routines : avoids "insufficient privileges to SHOW CREATE PROCEDURE" on RDS
# --skip-triggers : avoids similar privilege errors for triggers
# --skip-events   : avoids similar privilege errors for events
log "Pass 1: Dumping full database (schema + data)..."
mysqldump "${MYSQL_ARGS[@]}" \
  --single-transaction \
  --no-tablespaces \
  --set-gtid-purged=OFF \
  --skip-lock-tables \
  --skip-routines \
  --skip-triggers \
  --skip-events \
  "${IGNORE_FLAGS[@]}" \
  "$DB_NAME" \
  > "$TEMP_SQL"
log "Pass 1 complete."

# PASS 2: Schema-only for SCHEMA_ONLY_TABLES
if [[ ${#SCHEMA_ONLY_TABLES[@]} -gt 0 ]]; then
  log "Pass 2: Dumping schema-only for: ${SCHEMA_ONLY_TABLES[*]}..."
  mysqldump "${MYSQL_ARGS[@]}" \
    --no-data \
    --single-transaction \
    --no-tablespaces \
    --set-gtid-purged=OFF \
    --skip-lock-tables \
    "$DB_NAME" \
    "${SCHEMA_ONLY_TABLES[@]}" \
    >> "$TEMP_SQL"
  log "Pass 2 complete."
else
  warn "No schema-only tables specified. Skipping Pass 2."
fi

# -----------------------------------------------------------------------------
# COMPRESS (optional)
# -----------------------------------------------------------------------------
if [[ "$ZIP" == true ]]; then
  log "Compressing with gzip..."
  SQL_FILENAME="${OUTPUT_FILENAME%.gz}"
  TEMP_NAMED="$(dirname "$TEMP_SQL")/$SQL_FILENAME"
  mv "$TEMP_SQL" "$TEMP_NAMED"
  mkdir -p "$(dirname "$LOCAL_OUTPUT")"
  if [[ "$USE_PV" == true ]]; then
    pv "$TEMP_NAMED" | gzip > "$LOCAL_OUTPUT"
  else
    gzip -c "$TEMP_NAMED" > "$LOCAL_OUTPUT"
  fi
  rm -f "$TEMP_NAMED"
else
  mkdir -p "$(dirname "$LOCAL_OUTPUT")"
  mv "$TEMP_SQL" "$LOCAL_OUTPUT"
fi

# -----------------------------------------------------------------------------
# UPLOAD TO S3 (if -o was an S3 path)
# -----------------------------------------------------------------------------
if [[ "$IS_S3" == true ]]; then
  log "Uploading to S3: ${CYAN}$S3_DEST${NC}..."
  aws s3 cp "$LOCAL_OUTPUT" "$S3_DEST" \
    && log "Upload complete." \
    || error "S3 upload failed. Check your AWS credentials and bucket permissions."
  rm -f "$LOCAL_OUTPUT"
fi

# -----------------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------------
echo ""
log "Done!"
if [[ "$IS_S3" == true ]]; then
  log "File uploaded to: ${CYAN}$S3_DEST${NC}"
else
  SIZE=$(du -sh "$LOCAL_OUTPUT" | cut -f1)
  log "File saved to:    ${CYAN}$LOCAL_OUTPUT${NC} ($SIZE)"
fi
[[ ${#SKIP_TABLES[@]}        -gt 0 ]] && warn "Fully skipped (no schema, no data): ${SKIP_TABLES[*]}"
[[ ${#SCHEMA_ONLY_TABLES[@]} -gt 0 ]] && warn "Schema-only exported (no data):     ${SCHEMA_ONLY_TABLES[*]}"
[[ ${#VIEWS[@]}              -gt 0 ]] && warn "Views skipped (no SHOW VIEW privilege): ${VIEWS[*]}"