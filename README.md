# dbscripts

A pair of bash scripts for exporting and importing MySQL databases, with support for:

- Selective table export (schema-only or skip entirely) with wildcard patterns
- gzip compression
- Local and S3 storage

---

## Scripts

| Script | Purpose |
|---|---|
| `dbexp.sh` | Export (dump) a database |
| `dbimp.sh` | Import a dump file into a database |

---

## Requirements

- `mysql` and `mysqldump` — MySQL client tools
- `gzip` — for compression/decompression (usually pre-installed)
- `aws` CLI — only required when using S3 paths

---

## Installation

### One-liner (recommended)

Run this command in your terminal to download and install both scripts to `/usr/local/bin`:

```bash
curl -fsSL https://raw.githubusercontent.com/hoangnguyenba/dbscripts/main/install.sh | bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/hoangnguyenba/dbscripts/main/install.sh | bash
```

Once installed, the scripts are available system-wide as `dbexp` and `dbimp` (no `.sh` extension needed):

```bash
dbexp -d mydb -z -o /backups
dbimp -d mydb -i /backups/mydb.sql.gz
```

### Manual installation

If you prefer to install manually or want to keep the scripts editable:

```bash
# Clone the repo
git clone https://github.com/hoangnguyenba/dbscripts.git ~/projects/dbscripts

# Make scripts executable
chmod +x ~/projects/dbscripts/dbexp.sh
chmod +x ~/projects/dbscripts/dbimp.sh

# Add to PATH in your shell config
echo 'export PATH="$HOME/projects/dbscripts:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

> **Note:** With manual installation, any edits to the scripts take effect immediately — no re-installation needed.

### Updating

Re-run the one-liner at any time to update to the latest version:

```bash
curl -fsSL https://raw.githubusercontent.com/hoangnguyenba/dbscripts/main/install.sh | bash
```

---

## dbexp.sh — Export

### Options

| Flag | Long form | Description | Default |
|---|---|---|---|
| `-h` | `--host` | MySQL host | `localhost` |
| `-P` | `--port` | MySQL port | `3306` |
| `-u` | `--user` | MySQL user | `root` |
| `-p` | `--password` | MySQL password (prompted if omitted) | — |
| `-d` | `--database` | Database name | **(required)** |
| `-o` | `--output` | Output directory — local path or `s3://bucket/path` | current directory |
| `-f` | `--filename` | Output filename | `<dbname>_<timestamp>.sql[.gz]` |
| `-s` | `--schema-only` | Tables to export schema only, comma-separated | — |
| `-x` | `--skip` | Tables to skip entirely, comma-separated | — |
| `-z` | `--zip` | Compress output with gzip (auto-appends `.gz` if missing) | — |

### Table pattern wildcards

Use `%` as a wildcard in `-s` and `-x` to match multiple tables by prefix or pattern.
The script queries `information_schema` to resolve matching table names before the dump.

```
temp_%    →  temp_users, temp_logs, temp_data, ...
%_archive →  orders_archive, users_archive, ...
```

### Output path logic

`-o` and `-f` are combined to form the final destination:

```
-o /backups                      →  /backups/<dbname>_<timestamp>.sql
-o /backups -f mydb.sql          →  /backups/mydb.sql
-o /backups -f mydb.sql -z       →  /backups/mydb.sql.gz  (auto-appended .gz)
-o s3://my-bucket/backups        →  s3://my-bucket/backups/<dbname>_<timestamp>.sql.gz
-o s3://my-bucket/backups -f mydb.sql.gz  →  s3://my-bucket/backups/mydb.sql.gz
```

When the destination is an S3 path, the file is dumped locally to a temp file first, uploaded, then cleaned up automatically.

### Examples

```sh
# Minimal — dump to current directory
./dbexp.sh -d mydb

# Custom host and user
./dbexp.sh -d mydb -h 127.0.0.1 -P 3306 -u admin -p secret

# Export to local directory with compression
./dbexp.sh -d mydb -z -o /backups

# Custom filename (auto-appends .gz because -z is set)
./dbexp.sh -d mydb -z -o /backups -f mydb.sql
# → /backups/mydb.sql.gz

# Schema-only for some tables, skip others entirely (with wildcard)
./dbexp.sh -d mydb -s jobs,clients -x model_activities,temp_%

# Upload compressed dump to S3
./dbexp.sh -d mydb -z -o s3://my-bucket/backups/mysql

# Full example
./dbexp.sh \
  -h 127.0.0.1 \
  -P 3313 \
  -u root \
  -p secret \
  -d contentdb \
  -o ./backups \
  -s jobs,clients \
  -x model_activities,%temp_% \
  -z
```

---

## dbimp.sh — Import

### Options

| Flag | Long form | Description | Default |
|---|---|---|---|
| `-h` | `--host` | MySQL host | `localhost` |
| `-P` | `--port` | MySQL port | `3306` |
| `-u` | `--user` | MySQL user | `root` |
| `-p` | `--password` | MySQL password (prompted if omitted) | — |
| `-d` | `--database` | Target database name | **(required)** |
| `-i` | `--input` | Input file — local path or `s3://bucket/path/file.sql[.gz]` | **(required)** |

### Auto-detection

The script automatically detects and handles the input file:

| Condition | Action |
|---|---|
| Path starts with `s3://` | Downloads the file from S3 using the `aws` CLI |
| Filename ends with `.gz` | Decompresses with `gunzip` before import |
| Both | Downloads from S3, then decompresses |

Temp files are always cleaned up on exit, even if the script fails.

### Examples

```sh
# Local plain SQL
./dbimp.sh -d mydb -i /backups/mydb_20260426.sql

# Local compressed
./dbimp.sh -d mydb -i /backups/mydb_20260426.sql.gz

# From S3 (plain)
./dbimp.sh -d mydb -i s3://my-bucket/backups/mydb_20260426.sql

# From S3 (compressed) — download + decompress + import, fully automatic
./dbimp.sh -d mydb -i s3://my-bucket/backups/mydb_20260426.sql.gz

# Full example
./dbimp.sh \
  -h 127.0.0.1 \
  -P 3313 \
  -u root \
  -p secret \
  -d testdb \
  -i ./backups/contentdb_20260426_171540.sql.gz
```

---

## Tips

- Omit `-p` to be prompted for the password securely (it won't appear in shell history).
- Use `-z` with S3 uploads to reduce transfer size significantly.
- The `-x` flag is useful for skipping large log or activity tables that don't need to be transferred.
- The `-s` flag is useful for preserving table schemas in the target DB without copying data (e.g. empty staging tables).