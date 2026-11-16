#!/usr/bin/env bash
# corelab — static checks. Every config file is parsed by the (pinned) tool
# that uses it, from a container, with the repo mounted read-only.
# Output: one line per check, PASS <name> / FAIL <name> — <reason>; exit 1 on any failure.
#
# Usage: scripts/validate.sh
# Requires: Docker and Docker Compose on the workstation, internet (image pull, apt on the first run).
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/images.sh
source scripts/images.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { echo "PASS $1"; }
fail() {
  echo "FAIL $1 — $2"
  fails=$((fails + 1))
}
# check <name> <function>: on failure, the last 3 lines of the function's output are shown.
check() {
  local name=$1 out
  shift
  if out=$("$@" 2>&1); then
    pass "$name"
  else
    fail "$name" "$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  fi
}
run() { docker run --rm -v "$PWD":/w:ro -w /w "$@"; }
# Files that are (or would be) in the repo: tracked + untracked-but-not-ignored.
repo_files() { git ls-files -z -co --exclude-standard; }

# --- Test inputs: the sample lab values and a throwaway key/certificate ---
ssh-keygen -q -t ed25519 -N '' -C corelab-validate -f "$TMP/admin_key"
sed "s|^ADMIN_PUBKEY_FILE=.*|ADMIN_PUBKEY_FILE=$TMP/admin_key.pub|" examples/lab.env.example > "$TMP/lab.env"
printf 'RELAY_ADDR=192.0.2.20\n' > "$TMP/stack.env"
printf 'VM_ADDR=192.0.2.10\n' > "$TMP/ext.env"
mkdir -p "$TMP/secrets"
printf '[relay.corelab.test]:587 validate:validate\n' > "$TMP/secrets/relay_credentials"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj /CN=relay.corelab.test -keyout "$TMP/secrets/dummy.key" \
  -out "$TMP/secrets/relay_ca_cert" 2>/dev/null

# 1–2. Butane → Ignition
gate_butane() { scripts/render-ignition.sh "$TMP/lab.env" "$TMP/build"; }
gate_ignition() { jq -e '.ignition.version' "$TMP/build/app-01.ign"; }

# 3. Compose (app-01 and ext-01)
gate_compose() { docker compose --env-file "$TMP/stack.env" -f compose.yaml config -q; }
gate_compose_ext() {
  cp -r external "$TMP/external"
  touch "$TMP/external/checkmk.env"
  docker compose --env-file "$TMP/ext.env" -f "$TMP/external/compose.yaml" config -q
}

# 4–7. Caddy, Loki, Alloy, PHP
gate_caddy() { run "$CADDY_IMAGE" caddy validate --config Caddyfile --adapter caddyfile; }
gate_loki() {
  docker run --rm -v "$PWD/config/loki":/etc/loki:ro "$LOKI_IMAGE" \
    -config.file=/etc/loki/loki.yaml -verify-config
}
gate_alloy() {
  docker run --rm -v "$PWD/config/alloy":/c:ro "$ALLOY_IMAGE" fmt /c/config.alloy >/dev/null &&
    docker run --rm -v "$PWD/config/alloy":/c:ro "$ALLOY_IMAGE" validate /c/config.alloy
}
gate_php() { run "$PHP_CLI_IMAGE" php -l config/wordpress/mu-plugins/corelab-smtp.php; }

# 8. Postfix: build, postfix check (a warning is a failure too), required settings
gate_postfix() {
  local out
  docker build -q -t corelab-postfix:validate config/postfix >/dev/null || return 1
  out=$(docker run --rm \
    -v "$TMP/secrets/relay_credentials":/run/secrets/relay_credentials:ro \
    -v "$TMP/secrets/relay_ca_cert":/run/secrets/relay_ca_cert:ro \
    --entrypoint sh corelab-postfix:validate -c '
      postfix check || exit 1
      echo "level=$(postconf -h smtp_tls_security_level)"
      echo "relayhost=$(postconf -h relayhost)"
      echo "lookup=$(postconf -h smtp_host_lookup)"
      postconf -M postlog/unix-dgram | grep -q postlogd && echo "postlog=ok"
    ' 2>&1) || {
    echo "$out"
    return 1
  }
  if printf '%s\n' "$out" | grep -qE '(warning|fatal|error):'; then
    printf '%s\n' "$out" | grep -E '(warning|fatal|error):' | head -n 3
    return 1
  fi
  printf '%s\n' "$out" | grep -qxE 'level=(secure|verify)' || { echo "smtp_tls_security_level is not secure/verify"; return 1; }
  printf '%s\n' "$out" | grep -qx 'relayhost=\[relay.corelab.test\]:587' || { echo "relayhost differs"; return 1; }
  printf '%s\n' "$out" | grep -qx 'lookup=native' || { echo "smtp_host_lookup is not native"; return 1; }
  printf '%s\n' "$out" | grep -qx 'postlog=ok' || { echo "no postlog service"; return 1; }
}

# 9. Firewall: render, then a REAL load in a throwaway container's own network namespace.
#    (iptables-nft --test does not check jump targets; a real load does.)
fw_render() { CORELAB_FW_ENV="$TMP/lab.env" CORELAB_FW_DIR=firewall sh firewall/corelab-firewall render "$1"; }
gate_firewall() {
  printf 'FROM %s\nRUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends iptables >/dev/null && rm -rf /var/lib/apt/lists/*\n' \
    "$DEBIAN_IMAGE" > "$TMP/Dockerfile.fwtest"
  docker build -q -t corelab-fwtest:local -f "$TMP/Dockerfile.fwtest" "$TMP" >/dev/null || return 1
  fw_render host > "$TMP/host.rules" || return 1
  fw_render host6 > "$TMP/host6.rules" || return 1
  fw_render docker > "$TMP/docker-user.rules" || return 1
  # A fresh namespace has no DOCKER-USER chain: create it, for the test only.
  sed -i '/^\*filter/a :DOCKER-USER - [0:0]' "$TMP/docker-user.rules"
  docker run --rm -i --network none --cap-add NET_ADMIN corelab-fwtest:local iptables-restore < "$TMP/host.rules" || return 1
  docker run --rm -i --network none --cap-add NET_ADMIN corelab-fwtest:local ip6tables-restore < "$TMP/host6.rules" || return 1
  docker run --rm -i --network none --cap-add NET_ADMIN corelab-fwtest:local iptables-restore < "$TMP/docker-user.rules" || return 1
  grep -q -- '--ctorigdstport 443' "$TMP/docker-user.rules" || { echo "no --ctorigdstport 443 rule"; return 1; }
}

# 10. shellcheck
gate_shellcheck() {
  run "$SHELLCHECK_IMAGE" -x scripts/*.sh external/*.sh config/postfix/entrypoint.sh &&
    run "$SHELLCHECK_IMAGE" -s sh firewall/corelab-firewall monitoring/local/corelab_compose
}

# 11. Pinned images: every compose image has tag+digest and appears in images.sh
gate_pinning() {
  local img bad=0 from
  while read -r img; do
    [[ "$img" == "corelab-postfix:local" ]] && continue
    if [[ "$img" != *@sha256:* ]]; then
      echo "no digest: $img"
      bad=1
    elif ! grep -qF "=$img" scripts/images.sh; then
      echo "not in images.sh: $img"
      bad=1
    fi
  done < <(grep -hE '^\s+image:' compose.yaml external/compose.yaml | awk '{print $2}')
  from=$(awk '/^FROM /{print $2; exit}' config/postfix/Dockerfile)
  [[ "$from" == "$DEBIAN_IMAGE" ]] || { echo "the Postfix Dockerfile FROM differs from DEBIAN_IMAGE"; bad=1; }
  return "$bad"
}

# 12. Docs parity: every HU page has an EN partner with the same shape, and the
#     language switch on line 3 of both.
md_shape() {
  printf 'headings %s\nfences %s\ntable-lines %s\nimages %s\n' \
    "$(grep -cE '^#{1,4} ' "$1")" "$(grep -cE '^```' "$1")" \
    "$(grep -cE '^\|' "$1")" "$(grep -cE '!\[' "$1")"
}
gate_docs_parity() {
  local files f name hu en pair a b
  local -a pairs=(README.md:README.en.md external/README.md:external/README.en.md)
  files=$(repo_files | tr '\0' '\n')
  while read -r f; do
    name=${f#docs/??/}
    hu=docs/hu/$name
    en=docs/en/$name
    if ! grep -qxF "$hu" <<<"$files" || ! grep -qxF "$en" <<<"$files"; then
      echo "$f: no partner in the other language"
      return 1
    fi
    [[ $f == "$hu" ]] && pairs+=("$hu:$en")
  done < <(grep -E '^docs/(hu|en)/[^/]+\.md$' <<<"$files")
  for pair in "${pairs[@]}"; do
    hu=${pair%%:*}
    en=${pair##*:}
    for f in "$hu" "$en"; do
      grep -qxF "$f" <<<"$files" || { echo "$f: missing"; return 1; }
    done
    a=$(md_shape "$hu")
    b=$(md_shape "$en")
    if [[ "$a" != "$b" ]]; then
      paste -d' ' <(printf '%s\n' "$a") <(printf '%s\n' "$b") |
        awk -v f="$hu / $en" '$2 != $4 { print f ": " $1 " " $2 " vs " $4; exit }'
      return 1
    fi
    sed -n 3p "$hu" | grep -qE '^\*\*Magyar\*\* · \[English\]\(' ||
      { echo "$hu: line 3 is not the language switch"; return 1; }
    sed -n 3p "$en" | grep -qE '^\[Magyar\]\(.*\) · \*\*English\*\*$' ||
      { echo "$en: line 3 is not the language switch"; return 1; }
  done
}

# 13. Links: every relative link and #anchor in the docs resolves (offline, so the
#     https:// links are skipped).
gate_links() {
  run "$LYCHEE_IMAGE" --offline --include-fragments --no-progress \
    README.md README.en.md external/README.md external/README.en.md 'docs/**/*.md'
}

# 14. English code: no Hungarian letters outside the docs and the diagrams.
#     Written as code points, so this file does not match itself.
HU_LETTERS='[\x{e1}\x{e9}\x{ed}\x{f3}\x{f6}\x{151}\x{fa}\x{fc}\x{171}]'
gate_english_code() {
  local hits
  hits=$(repo_files | tr '\0' '\n' | grep -vE '(^docs/|\.md$|\.excalidraw$|\.svg$)' | tr '\n' '\0' |
    LC_ALL=C.UTF-8 xargs -0 -r grep -liP "$HU_LETTERS" -- || true)
  if [[ -n "$hits" ]]; then
    echo "Hungarian text in code: $(printf '%s' "$hits" | tr '\n' ' ')"
    return 1
  fi
}

# 15. Hygiene: forbidden names and addresses, files that must not be tracked.
#     Only repo files are scanned (repo_files), so ignored paths are left out.
gate_hygiene() {
  local pat hits files
  # The pattern is built from pieces so that this file does not match itself.
  pat="ne""xum|10\\.0\\.0\\.|@gm""ail|@icl""oud|w7-lo""qker|--inse""cure|curl[^|]* -""k( |\$)"
  hits=$(repo_files | xargs -0 -r grep -niIE "$pat" -- || true)
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | head -n 3
    return 1
  fi
  # PNG text chunks (tEXt/iTXt) can carry paths and names: scan the raw bytes.
  hits=$(repo_files | tr '\0' '\n' | grep '\.png$' | tr '\n' '\0' | xargs -0 -r grep -laE "$pat" -- || true)
  if [[ -n "$hits" ]]; then
    echo "forbidden pattern in PNG metadata: $hits"
    return 1
  fi
  files=$(repo_files | tr '\0' '\n' | grep -E '\.(ign|key|pem|htpasswd)$|(^|/)lab\.env$|(^|/)external/checkmk\.env$' || true)
  if [[ -n "$files" ]]; then
    echo "file that must not be tracked: $files"
    return 1
  fi
}

check butane-render gate_butane
check ignition-json gate_ignition
check compose-config gate_compose
check compose-config-ext gate_compose_ext
check caddy-validate gate_caddy
check loki-verify-config gate_loki
check alloy-fmt-validate gate_alloy
check php-lint gate_php
check postfix-check gate_postfix
check firewall-load gate_firewall
check shellcheck gate_shellcheck
check image-pinning gate_pinning
check docs-parity gate_docs_parity
check links gate_links
check english-code gate_english_code
check hygiene gate_hygiene

if ((fails)); then
  echo "Result: $fails check(s) failed"
  exit 1
fi
echo "Result: all checks PASS"
