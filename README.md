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
  -x model_activities,%temp_%
```

#### Import

```sh
mysql -h 127.0.0.1 -P 3313 -u root -ptest testdb3 < ./backups/contentdb3.sql
```