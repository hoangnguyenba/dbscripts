# dbscripts

A pair of bash scripts for exporting and importing MySQL databases with a clean CLI interface.

**Features:**

- Selective table export — schema-only or skip entirely, with `%` wildcard pattern support
- gzip compression with correct inner filename
- Local and S3 storage (auto-detects from path)
- Auto-download from S3 and auto-decompress on import
- Auto-create database on import if it doesn't exist
- `.env` file support — works out of the box in Laravel, Docker, and similar projects
- CLI arguments always take priority over `.env` values

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [.env Support](#env-support)
- [dbexp — Export](#dbexp--export)
- [dbimp — Import](#dbimp--import)
- [Tips](#tips)
- [License](#license)

---

## Requirements

- `mysql` and `mysqldump` — MySQL client tools
- `gzip` — for compression/decompression (usually pre-installed)
- `aws` CLI — only required when using S3 paths

---

## Installation

### One-liner (recommended)

Run this in your terminal to download and install both scripts to `/usr/local/bin`:

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

If you prefer to keep the scripts editable and version-controlled locally:

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

Re-run the one-liner at any time to pull the latest version:

```bash
curl -fsSL https://raw.githubusercontent.com/hoangnguyenba/dbscripts/main/install.sh | bash
```

---

## .env Support

Both scripts automatically load a `.env` file from the **current working directory** when you run them. This means if your project already has a `.env` (e.g. Laravel, Docker Compose), no connection flags are needed.

**Priority order:** `CLI argument` > `.env value` > built-in default

### Shared connection vars (`DB_`)

Recognised by both `dbexp` and `dbimp`:

| Key | Flag | Description |
|---|---|---|
| `DB_HOST` | `-h` | MySQL host |
| `DB_PORT` | `-P` | MySQL port |
| `DB_DATABASE` | `-d` | Database name |
| `DB_USERNAME` | `-u` | MySQL user |
| `DB_PASSWORD` | `-p` | MySQL password |

### Export vars (`DB_EXP_`)

Only read by `dbexp`:

| Key | Flag | Description |
|---|---|---|
| `DB_EXP_OUTPUT` | `-o` | Output directory — local path or `s3://bucket/path` |
| `DB_EXP_FILENAME` | `-f` | Output filename |
| `DB_EXP_SCHEMA_ONLY` | `-s` | Comma-separated tables to export schema only |
| `DB_EXP_SKIP` | `-x` | Comma-separated tables to skip entirely |
| `DB_EXP_ZIP` | `-z` | Set to `true` to enable gzip compression |

### Import vars (`DB_IMP_`)

Only read by `dbimp`:

| Key | Flag | Description |
|---|---|---|
| `DB_IMP_INPUT` | `-i` | Input file path — local or `s3://bucket/path/file.sql[.gz]` |
| `DB_IMP_CREATE_DB` | `-c` | Set to `true` to auto-create the database if it doesn't exist |

### Example `.env`

```env
# Shared — connection
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=contentdb
DB_USERNAME=root
DB_PASSWORD=secret

# Export defaults
DB_EXP_OUTPUT=./backups
DB_EXP_FILENAME=contentdb_latest.sql.gz
DB_EXP_SCHEMA_ONLY=jobs,clients
DB_EXP_SKIP=model_activities,temp_%
DB_EXP_ZIP=true

# Import defaults
DB_IMP_INPUT=./backups/contentdb_latest.sql.gz
DB_IMP_CREATE_DB=true
```

With this `.env` in place, you can run both scripts with zero arguments:

```bash
dbexp   # exports with all settings from .env
dbimp   # imports with all settings from .env
```

Override individual values as needed — CLI args always win:

```bash
dbexp -o s3://my-bucket/backups   # override output dir only
dbimp -d staging_db               # import into a different database
```

---

## dbexp — Export

Dumps a MySQL database to a `.sql` or `.sql.gz` file, locally or directly to S3.

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

Use `%` as a wildcard in `-s` and `-x` to match multiple tables by pattern. The script queries `information_schema` to resolve matches before dumping.

```
temp_%     →  temp_users, temp_logs, temp_data, ...
%_archive  →  orders_archive, users_archive, ...
```

### Output path logic

`-o` sets the directory and `-f` sets the filename. They combine to form the final destination:

```
-o /backups                               →  /backups/<dbname>_<timestamp>.sql
-o /backups -f mydb.sql                   →  /backups/mydb.sql
-o /backups -f mydb.sql -z               →  /backups/mydb.sql.gz  (auto-appended .gz)
-o s3://my-bucket/backups                 →  s3://my-bucket/backups/<dbname>_<timestamp>.sql.gz
-o s3://my-bucket/backups -f mydb.sql.gz  →  s3://my-bucket/backups/mydb.sql.gz
```

When uploading to S3, the file is written to a local temp file first, uploaded, then cleaned up automatically.

### Examples

```sh
# Minimal — dump to current directory
dbexp -d mydb

# Compressed export to local directory
dbexp -d mydb -z -o /backups

# Custom filename (auto-appends .gz because -z is set)
dbexp -d mydb -z -o /backups -f mydb.sql
# → /backups/mydb.sql.gz

# Schema-only for specific tables, skip others (with wildcard)
dbexp -d mydb -s jobs,clients -x model_activities,temp_%

# Upload compressed dump directly to S3
dbexp -d mydb -z -o s3://my-bucket/backups/mysql

# Full example
dbexp \
  -h 127.0.0.1 \
  -P 3313 \
  -u root \
  -p secret \
  -d contentdb \
  -o ./backups \
  -s jobs,clients \
  -x model_activities,temp_% \
  -z
```

---

## dbimp — Import

Imports a `.sql` or `.sql.gz` file into a MySQL database. Accepts a file path or a directory — if a directory is given, it automatically picks the latest dump file.

### Options

| Flag | Long form | Description | Default |
|---|---|---|---|
| `-h` | `--host` | MySQL host | `localhost` |
| `-P` | `--port` | MySQL port | `3306` |
| `-u` | `--user` | MySQL user | `root` |
| `-p` | `--password` | MySQL password (prompted if omitted) | — |
| `-d` | `--database` | Target database name | **(required)** |
| `-i` | `--input` | Input file or directory — local or `s3://bucket/path` | **(required)** |
| `-c` | `--create-db` | Create the database if it doesn't exist | — |

### Input resolution

The `-i` flag accepts either a **file path** or a **directory path** (local or S3):

| Input | Behaviour |
|---|---|
| Path to a `.sql` or `.sql.gz` file | Import that file directly |
| Path to a local directory | List all `.sql` / `.sql.gz` files, import the latest |
| S3 prefix (no file extension) | List all `.sql` / `.sql.gz` objects, import the latest |

Files are sorted by name descending to determine "latest" — this works naturally with the default `<dbname>_<timestamp>` naming from `dbexp`.

### Auto-detection

The script automatically handles the resolved file:

| Condition | Action |
|---|---|
| Path starts with `s3://` | Downloads from S3 using the `aws` CLI |
| Filename ends with `.gz` | Decompresses with `gunzip` before import |
| Both | Downloads from S3, then decompresses |

Temp files are always cleaned up on exit, even if the script fails mid-way.

### Examples

```sh
# Local — specific file
dbimp -d mydb -i /backups/mydb_20260426.sql.gz

# Local — directory (auto picks latest file)
dbimp -d mydb -i /backups

# S3 — specific file
dbimp -d mydb -i s3://my-bucket/backups/mydb_20260426.sql.gz

# S3 — prefix/directory (auto picks latest file)
dbimp -d mydb -i s3://my-bucket/backups

# Auto-create the database if it doesn't exist
dbimp -d newdb -i /backups -c

# Full example
dbimp \
  -h 127.0.0.1 \
  -P 3313 \
  -u root \
  -p secret \
  -d testdb \
  -c \
  -i ./backups
```

---

## Tips

- **Omit `-p`** to be prompted for the password securely — it won't appear in shell history.
- **Pair `DB_EXP_FILENAME` with `DB_IMP_INPUT`** to always export and import the same fixed filename (e.g. `contentdb_latest.sql.gz`) — useful for dev environment syncing.
- **Use `-z` with S3** to reduce transfer size and storage costs significantly.
- **Use `-x`** to skip large log, audit, or activity tables that don't need to be transferred between environments.
- **Use `-s`** to preserve table schemas in the target DB without copying data — useful for empty staging tables.
- **Use `-c`** when importing into a fresh environment where the database hasn't been created yet.

---

## License

MIT License

Copyright (c) 2026 Hoang Nguyen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.