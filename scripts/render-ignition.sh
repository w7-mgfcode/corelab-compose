#!/usr/bin/env bash
# corelab — lab.env → build/{admin.pub,firewall.env,stack.env} → build/app-01.ign
#
# Usage: scripts/render-ignition.sh [ENV_FILE] [OUT_DIR]
#   ENV_FILE  default: lab.env (in the repo root, untracked)
#   OUT_DIR   default: build
#
# Butane runs from the pinned container image, with the repo mounted
# read-only. OUT_DIR is always mounted at /w/build, because app-01.bu
# refers to build/… paths (relative to --files-dir).
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/images.sh
source scripts/images.sh

ENV_FILE=${1:-lab.env}
OUT_DIR=${2:-build}
REQUIRED_KEYS=(VM_ADDR EXT_IF ADMIN_SRC CLIENT_NET CHECKMK_SRC RELAY_ADDR ADMIN_PUBKEY_FILE)

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL render — no such env file: $ENV_FILE (sample: examples/lab.env.example)" >&2
  exit 2
fi

# The env file's values live only in this process.
# shellcheck disable=SC1090
source "$ENV_FILE"

missing=()
for key in "${REQUIRED_KEYS[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    missing+=("$key")
  fi
done
if ((${#missing[@]})); then
  echo "FAIL render — missing or empty key(s): ${missing[*]}" >&2
  exit 2
fi

pubkey=${ADMIN_PUBKEY_FILE/#\~/$HOME}
if [[ ! -s "$pubkey" ]]; then
  echo "FAIL render — ADMIN_PUBKEY_FILE is unreadable or empty" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"
cp "$pubkey" "$OUT_DIR/admin.pub"

{
  printf 'VM_ADDR=%s\n' "$VM_ADDR"
  printf 'EXT_IF=%s\n' "$EXT_IF"
  printf 'ADMIN_SRC=%s\n' "$ADMIN_SRC"
  printf 'CLIENT_NET=%s\n' "$CLIENT_NET"
  printf 'CHECKMK_SRC=%s\n' "$CHECKMK_SRC"
} > "$OUT_DIR/firewall.env"

printf 'RELAY_ADDR=%s\n' "$RELAY_ADDR" > "$OUT_DIR/stack.env"

out_abs=$(realpath "$OUT_DIR")
# The /w/build mount point must exist under the read-only /w
# (Docker cannot create a directory there). build/ is in .gitignore.
mkdir -p build
# Render to a temporary file first, so a failure leaves no half-written .ign.
tmp_ign="$out_abs/.app-01.ign.partial"
trap 'rm -f "$tmp_ign"' EXIT
docker run --rm \
  -v "$PWD":/w:ro \
  -v "$out_abs":/w/build \
  -w /w \
  "$BUTANE_IMAGE" --strict --files-dir /w butane/app-01.bu > "$tmp_ign"
mv "$tmp_ign" "$out_abs/app-01.ign"

echo "Ignition: $out_abs/app-01.ign"
sha256sum "$out_abs/app-01.ign" | awk '{print "sha256: " $1}'
