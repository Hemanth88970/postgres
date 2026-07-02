#!/bin/sh
# init-replica.sh
#
# Runs as an initContainer before the postgres container starts.
# - If the data directory is empty, it clones the primary with pg_basebackup
#   using the replication user, and writes the recovery/standby config via
#   the -R flag (creates standby.signal + postgresql.auto.conf automatically).
# - If the data directory already has data (e.g. pod restarted), it does
#   nothing and lets postgres start normally as a standby.
set -e

PGDATA_DIR="/var/lib/postgresql/data/pgdata"
PRIMARY_HOST="${PRIMARY_HOST:-postgres-primary}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPLICATION_USER="${REPLICATION_USER:-replicator}"
REPLICATION_SLOT="${REPLICATION_SLOT:-replica1_slot}"

echo "[init-replica] Checking data directory: ${PGDATA_DIR}"

if [ -s "${PGDATA_DIR}/PG_VERSION" ]; then
  echo "[init-replica] Existing PGDATA found, skipping base backup."
  exit 0
fi

echo "[init-replica] No existing PGDATA, waiting for primary at ${PRIMARY_HOST}:${PRIMARY_PORT} to accept connections..."

until PGPASSWORD="${REPLICATION_PASSWORD}" pg_isready -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REPLICATION_USER}"; do
  echo "[init-replica] Primary not ready yet, retrying in 3s..."
  sleep 3
done

echo "[init-replica] Primary is ready. Running pg_basebackup..."

mkdir -p "${PGDATA_DIR}"
chmod 0700 "${PGDATA_DIR}"

# pg_basebackup -R writes primary_conninfo with host/port/user but NOT the
# password. Without a .pgpass file the replica would fail to reconnect to
# the primary after any restart. Write one so streaming survives restarts.
PGPASS_FILE="${HOME:-/var/lib/postgresql}/.pgpass"
echo "${PRIMARY_HOST}:${PRIMARY_PORT}:*:${REPLICATION_USER}:${REPLICATION_PASSWORD}" > "${PGPASS_FILE}"
chmod 0600 "${PGPASS_FILE}"

PGPASSWORD="${REPLICATION_PASSWORD}" pg_basebackup \
  -h "${PRIMARY_HOST}" \
  -p "${PRIMARY_PORT}" \
  -U "${REPLICATION_USER}" \
  -D "${PGDATA_DIR}" \
  -Fp -Xs -P -R \
  -S "${REPLICATION_SLOT}" \
  -C

echo "[init-replica] Base backup complete. standby.signal + primary_conninfo written by -R flag."
echo "[init-replica] Replica bootstrap finished."
