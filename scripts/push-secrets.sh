#!/usr/bin/env bash
# corelab — upload the secrets to app-01 over SSH.
#
# Usage: scripts/push-secrets.sh <vm-ssh-target>      for example: core@192.0.2.10
# Source: ${CORELAB_SECRETS_DIR:-~/.config/corelab/secrets}
#
# On the VM: /var/lib/corelab/secrets (root, 0700), files root 0444, SELinux label
# container_file_t, and LAST the .ready marker file. The files are 0444 because
# the containers read them with different UIDs (MariaDB 999, WordPress 33, Grafana 472);
# the 0700 parent directory means only root can reach them on the host.
# It prints only names, never values.
set -euo pipefail

target=${1:?usage: scripts/push-secrets.sh <vm-ssh-target>}
dir=${CORELAB_SECRETS_DIR:-$HOME/.config/corelab/secrets}
names=(db_root_password db_wordpress_password wordpress_admin_password grafana_admin_password relay_credentials relay_ca_cert)

files=()
missing=()
for name in "${names[@]}"; do
  if [[ -s "$dir/$name" ]]; then
    files+=("$dir/$name")
  else
    missing+=("$name")
  fi
done
if ((${#missing[@]})); then
  echo "FAIL push-secrets — missing secret(s): ${missing[*]} (scripts/gen-secrets.sh)" >&2
  exit 1
fi

# Format check, without printing any value
if ! grep -qE '^\[relay\.corelab\.test\]:587 [^ :]+:.+$' "$dir/relay_credentials"; then
  echo "FAIL push-secrets — relay_credentials format: [relay.corelab.test]:587 <user>:<password>" >&2
  exit 1
fi
if ! openssl x509 -in "$dir/relay_ca_cert" -noout 2>/dev/null; then
  echo "FAIL push-secrets — relay_ca_cert is not a readable PEM certificate" >&2
  exit 1
fi

remote_tmp=$(ssh "$target" 'mktemp -d')
if [[ ! "$remote_tmp" =~ ^/tmp/tmp\.[A-Za-z0-9]+$ ]]; then
  echo "FAIL push-secrets — unexpected temporary directory name on the VM" >&2
  exit 1
fi

scp -q "${files[@]}" "$target:$remote_tmp/"

# $remote_tmp is expanded on the client side on purpose (the value is checked above).
# shellcheck disable=SC2029
ssh "$target" "sudo sh -s -- '$remote_tmp'" <<'REMOTE'
set -eu
src=$1
dest=/var/lib/corelab/secrets
rm -f "$dest/.ready"
install -d -o root -g root -m 0700 "$dest"
for name in db_root_password db_wordpress_password wordpress_admin_password grafana_admin_password relay_credentials relay_ca_cert; do
  install -o root -g root -m 0444 "$src/$name" "$dest/$name"
done
chcon -R -t container_file_t "$dest"
rm -rf "$src"
touch "$dest/.ready"
REMOTE

for name in "${names[@]}"; do
  echo "uploaded: $name"
done
echo "uploaded: .ready (last)"
