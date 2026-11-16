#!/usr/bin/env bash
# corelab — end-to-end smoke test against the installed lab (runs from the workstation).
#
# Required environment variables:
#   VM               SSH target for app-01 (e.g. core@192.0.2.10)
#   VM_ADDR          app-01 address (for the port checks)
#   EXT              ext-01 address (Mailpit API)
#   LAB_CA_CERT      Caddy's internal root certificate (exported, docs/en/install.md step 9)
#   MAILPIT_UI_AUTH  "user:password" for the Mailpit UI (never printed)
# Requires: app.corelab.test and logs.corelab.test resolve to VM_ADDR (/etc/hosts).
#
# Output: one line per check, PASS <name> / FAIL <name> — <reason>; exit 1 if any fails.
# Every blocking (negative) check has an allowing control in the same run,
# so a negative result proves more than just a missing route.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/images.sh
source scripts/images.sh

missing=()
for v in VM VM_ADDR EXT LAB_CA_CERT MAILPIT_UI_AUTH; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if ((${#missing[@]})); then
  echo "FAIL smoke-test — missing variable(s): ${missing[*]}" >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

epoch=$(date +%s)
subj="corelab-smoke-$epoch"
rcpt="smoke-$epoch@example.test"
token404="corelab-smoke-404-$epoch"
STACK=/var/lib/corelab/stack
total=0
fails=0
queue_id=""

pass() {
  total=$((total + 1))
  echo "PASS $1"
}
fail() {
  total=$((total + 1))
  fails=$((fails + 1))
  echo "FAIL $1 — $2"
}
vm() { ssh -o BatchMode=yes "$VM" "$@"; }
compose() { vm "cd $STACK && sudo docker compose $*"; }

# Loki query on the VM, from the internal "logs" network; output: number of hits
loki_count() {
  local query=$1
  printf "curl -fsS -G http://loki:3100/loki/api/v1/query_range --data-urlencode 'query=%s' --data-urlencode since=30m\n" "$query" |
    vm "sudo docker run --rm -i --network corelab_logs --entrypoint sh $CURL_IMAGE -s" |
    jq -e '[.data.result[].values | length] | add // 0'
}

# 1. HTTPS with the lab root
code=$(curl -sS --cacert "$LAB_CA_CERT" -o /dev/null -w '%{http_code}' https://app.corelab.test/ || true)
case $code in
  200 | 301 | 302) pass https-app ;;
  *) fail https-app "HTTP $code" ;;
esac

# 2. Control: with a foreign CA the connection must fail with a certificate error (60)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj /CN=corelab-untrusted -keyout "$TMP/u.key" -out "$TMP/untrusted.crt" 2>/dev/null
rc=0
curl -sS --cacert "$TMP/untrusted.crt" -o /dev/null https://app.corelab.test/ 2>/dev/null || rc=$?
if [[ $rc -eq 60 ]]; then pass https-untrusted-control; else fail https-untrusted-control "curl exit $rc (expected 60)"; fi

# 3. Grafana without login: 401
code=$(curl -sS --cacert "$LAB_CA_CERT" -o /dev/null -w '%{http_code}' https://logs.corelab.test/api/datasources || true)
if [[ $code == 401 ]]; then pass https-logs-login; else fail https-logs-login "HTTP $code (expected 401)"; fi

# 4. Port 80 closed
rc=0
curl -sS --connect-timeout 5 -o /dev/null http://app.corelab.test/ 2>/dev/null || rc=$?
if [[ $rc -eq 7 || $rc -eq 28 ]]; then pass http-closed; else fail http-closed "curl exit $rc (expected 7 or 28)"; fi

# 5. Every service is running, MariaDB is healthy
if ps_json=$(compose ps --format json 2>/dev/null); then
  bad=$(printf '%s\n' "$ps_json" | jq -rs '
    (if (.[0] | type) == "array" then .[0] else . end) as $s
    | ["caddy","wordpress","mariadb","postfix","loki","alloy","grafana"] as $want
    | [ $want[] as $w | ($s | map(select(.Service == $w)) | first) as $c
        | if $c == null then "\($w):absent"
          elif $c.State != "running" then "\($w):\($c.State)"
          elif $w == "mariadb" and $c.Health != "healthy" then "mariadb:\($c.Health)"
          else empty end ]
    | join(" ")')
  if [[ -z "$bad" ]]; then pass stack-state; else fail stack-state "$bad"; fi
else
  fail stack-state "docker compose ps failed"
fi

# 6. Send a mail from WordPress (wpcli, same mu-plugin)
if compose run --rm -T wpcli wp eval "'exit(wp_mail(\"$rcpt\", \"$subj\", \"corelab smoke\") ? 0 : 1);'" >/dev/null 2>&1; then
  pass mail-send
else
  fail mail-send "wp_mail returned false or wpcli did not run"
fi

# 7. Queue ID from the Postfix log (status=sent to the relay), at most 30 s
maillog=""
for _ in $(seq 1 15); do
  maillog=$(compose exec -T postfix tail -n 2000 /var/log/postfix/mail.log 2>/dev/null || true)
  line=$(printf '%s\n' "$maillog" | grep -F "to=<$rcpt>" | grep -F 'relay=relay.corelab.test' | grep -F 'status=sent' | tail -n 1 || true)
  if [[ -n "$line" ]]; then
    queue_id=$(printf '%s\n' "$line" | sed -nE 's/.*postfix\/smtp\[[0-9]+\]: ([0-9A-Za-z]+):.*/\1/p')
    break
  fi
  sleep 2
done
if [[ -n "$queue_id" ]]; then pass mail-queue-id; else fail mail-queue-id "no status=sent line for the recipient"; fi

# 8. Verified TLS to the relay
if printf '%s\n' "$maillog" | grep -qF 'Verified TLS connection established to relay.corelab.test'; then
  pass mail-tls-verified
else
  fail mail-tls-verified "no 'Verified TLS connection established' line"
fi

# 9. The mail arrived in Mailpit (the password goes through curl's config stdin)
count=0
for _ in $(seq 1 10); do
  count=$(printf 'user = "%s"\n' "$MAILPIT_UI_AUTH" |
    curl -fsS --config - -G "http://$EXT:8025/api/v1/search" --data-urlencode "query=subject:\"$subj\"" 2>/dev/null |
    jq -r '.messages | length' 2>/dev/null || echo 0)
  [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] && break
  sleep 2
done
if [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]]; then pass mail-arrived; else fail mail-arrived "0 hits in Mailpit"; fi

# 10. Relay refusal: an untrusted address on the "mail" network -> 220 banner, then 5.7.1 on RCPT
probe=$(vm "sudo docker run --rm -i --network corelab_mail --ip 172.30.10.99 $DEBIAN_IMAGE bash -s" <<'PROBE' 2>/dev/null || true
exec 3<>/dev/tcp/postfix/25 || { echo "noconnect"; exit 0; }
read -r -t 10 line <&3 || { echo "nobanner"; exit 0; }
case $line in 220*) echo "banner:220" ;; *) echo "nobanner"; exit 0 ;; esac
printf 'EHLO probe.corelab.test\r\n' >&3
while read -r -t 10 line <&3; do
  case $line in "250 "*) break ;; 250-*) ;; *) echo "ehlo:${line%%$'\r'}"; exit 0 ;; esac
done
printf 'MAIL FROM:<probe@corelab.test>\r\n' >&3
read -r -t 10 line <&3; echo "mail:${line%%$'\r'}"
printf 'RCPT TO:<x@example.com>\r\n' >&3
read -r -t 10 line <&3; echo "rcpt:${line%%$'\r'}"
printf 'QUIT\r\n' >&3
PROBE
)
if printf '%s\n' "$probe" | grep -qx 'banner:220' && printf '%s\n' "$probe" | grep -qE '^rcpt:5[0-9][0-9][ -]5\.7\.1'; then
  pass relay-refused
else
  fail relay-refused "$(printf '%s' "$probe" | tr '\n' ' ')"
fi

# 11. An HTTP error is searchable in Loki
curl -sS --cacert "$LAB_CA_CERT" -o /dev/null "https://app.corelab.test/$token404" || true
n=0
for _ in $(seq 1 15); do
  n=$(loki_count "{service=\"caddy\"} |= \"$token404\"" 2>/dev/null || echo 0)
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] && break
  sleep 4
done
if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]]; then pass logs-http-error; else fail logs-http-error "0 hits in Loki"; fi

# 12. The mail's queue ID is searchable in Loki
if [[ -z "$queue_id" ]]; then
  fail logs-queue-id "no queue ID (check 7)"
else
  n=0
  for _ in $(seq 1 15); do
    n=$(loki_count "{service=\"postfix\"} |= \"$queue_id\"" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] && break
    sleep 4
  done
  if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]]; then pass logs-queue-id; else fail logs-queue-id "0 hits in Loki"; fi
fi

# 13. Control: 0 hits for a token never sent (and the query itself succeeds)
if n=$(loki_count "{service=\"caddy\"} |= \"corelab-never-sent-$epoch\"" 2>/dev/null) && [[ "$n" == 0 ]]; then
  pass logs-control
else
  fail logs-control "expected 0, got: ${n:-error}"
fi

# 14. Closed ports from outside, with the open 443 as the control
if nc -z -w3 "$VM_ADDR" 443; then
  open=""
  for p in 80 25 3100 3000 8080; do
    if nc -z -w3 "$VM_ADDR" "$p" 2>/dev/null; then open="$open $p"; fi
  done
  if [[ -z "$open" ]]; then pass fw-closed-ports; else fail fw-closed-ports "open port(s):$open"; fi
else
  fail fw-closed-ports "the 443 control is not reachable either"
fi

# 15. The DOCKER-USER rule matches the original destination port
if vm "sudo /usr/local/sbin/corelab-firewall status" 2>/dev/null | grep -q -- '--ctorigdstport 443'; then
  pass fw-rules
else
  fail fw-rules "no --ctorigdstport 443 in the DOCKER-USER chain"
fi

echo "Result: $((total - fails))/$total PASS"
if ((fails)); then exit 1; fi
