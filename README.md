# Local, default filename
./mysqldump_selective.sh -d mydb -o /backups
# → /backups/mydb_20260426_120000.sql

# Local, custom filename + zip
./mysqldump_selective.sh -d mydb -z -o /backups -f mydb.sql
# → /backups/mydb.sql.gz  (auto-appended .gz)

# S3, default filename
./mysqldump_selective.sh -d mydb -z -o s3://my-bucket/backups/mysql
# → s3://my-bucket/backups/mysql/mydb_20260426_120000.sql.gz

# S3, custom filename
./mysqldump_selective.sh -d mydb -z -o s3://my-bucket/backups -f mydb.sql.gz
# → s3://my-bucket/backups/mydb.sql.gz


# Local plain SQL
./dbimp.sh -d mydb -i /backups/mydb_20260426.sql

# Local compressed
./dbimp.sh -d mydb -i /backups/mydb_20260426.sql.gz

# S3 plain SQL
./dbimp.sh -d mydb -i s3://my-bucket/backups/mydb_20260426.sql

# S3 compressed (download + decompress + import, fully automatic)
./dbimp.sh -d mydb -i s3://my-bucket/backups/mydb_20260426.sql.gz

# testdb

#### Export

```sh
./dbexp.sh \
  -h 127.0.0.1 \
  -P 3313 \
  -u root \
  -p test \
  -d contentdb \
  -o ./backups/contentdb3.sql \
  -s jobs,clients \
  -x model_activities,%temp_% \
  -z
```

#### Import

```sh
./dbimp.sh \
  -h 127.0.0.1 \
  -P 3313 \
  -u root \
  -p test \
  -d testdb5 \
  -i ./backups/contentdb_20260426_171540.sql.gz
```