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


# commerce

```sh
./mysqldump_selective.sh \
  -h 127.0.0.1 \
  -P 43306 \
  -u root \
  -p example \
  -d commercedb \
  -o ./backups/commercedb.sql \
  -s sync_requests,sync_request_jobs \
  -x postal_delivery_options
```


# contentdb

#### Export

```sh
./mysqldump_selective.sh \
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
mysql -h 127.0.0.1 -P 3313 -u root -ptest testdb3 < ./backups/contentdb3.sql
```