#!/usr/bin/env bash
# corelab — create random secrets on the workstation.
#
# Usage: scripts/gen-secrets.sh
# Target directory: ${CORELAB_SECRETS_DIR:-~/.config/corelab/secrets} (0700, files 0600).
# It never overwrites an existing file, so it can be run again. It never prints values,
# only names. relay_credentials and relay_ca_cert come from the ext-01 setup.
set -euo pipefail

repo=$(realpath "$(dirname "$0")/..")
dir=${CORELAB_SECRETS_DIR:-$HOME/.config/corelab/secrets}
dir_abs=$(realpath -m "$dir")

case "$dir_abs/" in
  "$repo/"*)
    echo "FAIL gen-secrets — the secrets directory must not be inside the repo: $dir_abs" >&2
    exit 1
    ;;
esac

umask 077
mkdir -p "$dir_abs"
chmod 0700 "$dir_abs"

for name in db_root_password db_wordpress_password wordpress_admin_password grafana_admin_password; do
  if [[ -s "$dir_abs/$name" ]]; then
    echo "kept:        $name"
  else
    openssl rand -base64 32 | tr -d '\n/+=' > "$dir_abs/$name"
    chmod 0600 "$dir_abs/$name"
    echo "created:     $name"
  fi
done

for name in relay_credentials relay_ca_cert; do
  if [[ -s "$dir_abs/$name" ]]; then
    echo "present:     $name"
  else
    echo "MISSING:     $name"
  fi
done

cat <<EOF

Put the two relay secrets into $dir_abs by hand (mode 0600):
  relay_credentials  one line: [relay.corelab.test]:587 <user>:<password>
                     (the Mailpit smtp.htpasswd user and password, external/README.en.md step 3)
  relay_ca_cert      ext-01's tls/relay.crt file (PEM; external/README.en.md step 2)
EOF
