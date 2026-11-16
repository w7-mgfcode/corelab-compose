#!/usr/bin/env bash
# corelab — simple backup on app-01 (OPTIONAL part).
#
# Run on the VM, as root: sudo ./backup.sh
# images.sh must sit next to the script (for DEBIAN_IMAGE);
# copy both from the repo's scripts/ directory to the VM.
#
# Contents: a MariaDB dump (consistent, --single-transaction), plus the
# wp_html, caddy_data (it holds the internal CA's private key!) and grafana_data volumes.
# Loki data is treated as rebuildable and is not included. The source of the secrets
# is the workstation. Destination: /var/lib/corelab/backup/<timestamp> (0700, root).
# The last 7 backups are kept. Copying off the VM is a recommendation, not part of the script.
set -euo pipefail

here=$(dirname "$(realpath "$0")")
# shellcheck source=scripts/images.sh
source "$here/images.sh"

STACK_DIR=/var/lib/corelab/stack
BACKUP_ROOT=/var/lib/corelab/backup
KEEP=7

if [[ $EUID -ne 0 ]]; then
  echo "FAIL backup — must run as root" >&2
  exit 1
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
dest="$BACKUP_ROOT/$ts"
umask 077
install -d -m 0700 "$BACKUP_ROOT"
install -d -m 0700 "$dest"

cd "$STACK_DIR"

# The password goes in an environment variable, not a command-line argument.
docker compose exec -T mariadb sh -c \
  'MYSQL_PWD="$(cat /run/secrets/db_root_password)" exec mariadb-dump --single-transaction -uroot wordpress' \
  > "$dest/wordpress.sql"
echo "PASS backup: wordpress.sql"

for vol in wp_html caddy_data grafana_data; do
  docker run --rm \
    -v "corelab_${vol}:/v:ro" \
    -v "$dest:/b:z" \
    "$DEBIAN_IMAGE" tar -C /v -czf "/b/${vol}.tgz" .
  echo "PASS backup: ${vol}.tgz"
done

chmod 0600 "$dest"/*
sha256sum "$dest"/* > "$dest/SHA256SUMS"
chmod 0600 "$dest/SHA256SUMS"

# Keep only the last KEEP backups
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n "-$KEEP" | xargs -r rm -rf --

echo "Backup done: $dest"
