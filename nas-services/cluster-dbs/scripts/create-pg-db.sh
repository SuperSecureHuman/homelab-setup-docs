#!/usr/bin/env bash
# Creates a Postgres database + user and registers it in pgbouncer.
# Usage: ./create-pg-db.sh <dbname> <username> <password>
set -euo pipefail

DB=$1; USER=$2; PASS=$3
BASE=/mnt/ssd_mirror/docker_mounts/cluster_dbs
CONTAINER=cluster-dbs-postgres-1
BOUNCER=cluster-dbs-pgbouncer-1

echo "Creating database '$DB' with user '$USER'..."

docker exec -i "$CONTAINER" psql -U admin -d postgres -c "CREATE DATABASE $DB;"

docker exec -i "$CONTAINER" psql -U admin -d postgres -c "
  SET password_encryption = 'md5';
  CREATE USER $USER WITH PASSWORD '$PASS';
  GRANT ALL PRIVILEGES ON DATABASE $DB TO $USER;
  ALTER DATABASE $DB OWNER TO $USER;
"

sed -i "/^\[pgbouncer\]/i $DB = host=postgres port=5432 dbname=$DB" "$BASE/pgbouncer/pgbouncer.ini"

echo "\"$USER\" \"$PASS\"" >> "$BASE/pgbouncer/userlist.txt"

docker kill --signal=HUP "$BOUNCER"

echo "Done. Connect via NAS_IP:5432 dbname=$DB user=$USER"
