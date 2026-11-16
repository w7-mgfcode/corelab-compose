#!/usr/bin/env bash
# corelab — self-signed certificate for the relay (Mailpit, ext-01).
# SAN: relay.corelab.test. relay.crt becomes Postfix's trust anchor
# (the relay_ca_cert secret on app-01); relay.key never leaves ext-01.
#
# Usage: external/make-relay-cert.sh [OUT_DIR]   (default: ./tls)
set -euo pipefail

OUT_DIR=${1:-./tls}
mkdir -p "$OUT_DIR"

if [[ -e "$OUT_DIR/relay.key" || -e "$OUT_DIR/relay.crt" ]]; then
  echo "FAIL relay-cert — already exists: $OUT_DIR/relay.{key,crt}; not overwriting" >&2
  exit 1
fi

umask 077
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 825 -nodes \
  -subj "/CN=relay.corelab.test" \
  -addext "subjectAltName=DNS:relay.corelab.test" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -keyout "$OUT_DIR/relay.key" -out "$OUT_DIR/relay.crt" 2>/dev/null
chmod 0600 "$OUT_DIR/relay.key"
# Let the Mailpit container read the certificate as a non-root user
chmod 0644 "$OUT_DIR/relay.crt"

echo "relay.crt: $OUT_DIR/relay.crt"
openssl x509 -in "$OUT_DIR/relay.crt" -noout -fingerprint -sha256
