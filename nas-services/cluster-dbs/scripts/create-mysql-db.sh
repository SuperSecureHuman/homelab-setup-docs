#!/usr/bin/env bash
# Creates a MariaDB database + user and registers the user in ProxySQL.
# Usage: ./create-mysql-db.sh <dbname> <username> <password>
set -euo pipefail

DB=$1; USER=$2; PASS=$3
CONTAINER=cluster_dbs-mariadb-1
PROXYSQL=cluster_dbs-proxysql-1

echo "Creating database '$DB' with user '$USER'..."

docker exec -i "$CONTAINER" mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "
  CREATE DATABASE IF NOT EXISTS $DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS '$USER'@'%' IDENTIFIED BY '$PASS';
  GRANT ALL PRIVILEGES ON $DB.* TO '$USER'@'%';
  FLUSH PRIVILEGES;
"

docker exec -i "$PROXYSQL" mysql -h 127.0.0.1 -P 6032 -u admin -p"${PROXYSQL_ADMIN_PASSWORD}" -e "
  INSERT INTO mysql_users(username,password,default_hostgroup) VALUES ('$USER','$PASS',0);
  LOAD MYSQL USERS TO RUNTIME;
  SAVE MYSQL USERS TO DISK;
"

echo "Done. Connect via NAS_IP:3306 dbname=$DB user=$USER"
