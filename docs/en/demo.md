# Demo: 10 minutes live

[Magyar](../hu/demo.md) · **English**

A script for a live call: eight steps, each with what it shows, the exact command or URL, and the expected result in one line. The steps assume the installed lab ([install.md](install.md), steps 0–11); the recorded outputs that belong to them live in [evidence.md](evidence.md).

Preparation on the workstation: the `/etc/hosts` entry (`192.0.2.10  app.corelab.test logs.corelab.test`), the exported root certificate at `~/.config/corelab/corelab-root.crt`, and two open browser tabs: Grafana (`https://logs.corelab.test/`) and the Mailpit UI (`http://192.0.2.20:8025/`).

| Step | Topic | Time |
|---|---|---|
| 1 | static validation | 1 min |
| 2 | Fedora CoreOS and Docker CE | 1 min |
| 3 | HTTPS with the internal CA | 1 min |
| 4 | mail from WordPress to Mailpit | 1.5 min |
| 5 | log search in Grafana | 1.5 min |
| 6 | firewall: block and control | 1.5 min |
| 7 | Checkmk alert | 1.5 min |
| 8 | smoke test | 1 min |

## 1. Static validation

- **Shows:** every config file is processed by the pinned tool that uses it; the same run happens in CI.
- **Expected:** 16 `PASS` lines, the last line `Result: all checks PASS`.
- **Evidence:** [evidence.md](evidence.md) (status words), the CI badge in the README.

```bash
scripts/validate.sh
```

## 2. Fedora CoreOS and Docker CE

- **Shows:** the VM runs FCOS, with Docker CE instead of the built-in Moby (`rpm-ostree override`).
- **Expected:** the `docker-ce` package version, and `rpm-ostree status` shows the overridden (removed) Moby packages and the layered `docker-ce`.
- **Evidence:** [evidence.md, 1.](evidence.md#1-fedora-coreos-under-proxmox) and [2.](evidence.md#2-docker-ce-not-the-built-in-moby)

```bash
ssh core@192.0.2.10 'rpm -q docker-ce; rpm-ostree status | head -n 6'
```

## 3. HTTPS with the internal CA

- **Shows:** Caddy serves a certificate issued by the internal CA, and the client verifies it against the lab root; certificate verification is on.
- **Expected:** an `HTTP/2` status line (200 or a redirect), with no certificate error.
- **Evidence:** [evidence.md, 5.](evidence.md#5-https-terminating-reverse-proxy-caddy) and [6.](evidence.md#6-internal-https-with-an-internal-ca-and-automatic-certificate-issuance)

```bash
curl --cacert ~/.config/corelab/corelab-root.crt -sI https://app.corelab.test/
```

## 4. Mail from WordPress to Mailpit

- **Shows:** WordPress (with the same mu-plugin, through `wpcli`) sends a mail; Postfix hands it to the relay with verified TLS and authentication.
- **Expected:** the command exits 0, the mail appears in the Mailpit UI with the subject `corelab demo`, and the Postfix log shows `status=sent` and a queue ID.
- **Evidence:** [evidence.md, 7.](evidence.md#7-postfix-smtp-container-that-the-services-send-mail-through)

```bash
ssh core@192.0.2.10
cd /var/lib/corelab/stack
sudo docker compose run --rm -T wpcli wp eval 'exit(wp_mail("demo@example.test", "corelab demo", "corelab demo") ? 0 : 1);'
sudo docker compose exec -T postfix tail -n 20 /var/log/postfix/mail.log
```

## 5. Log search in Grafana

- **Shows:** the mail's queue ID and the web errors are searchable in Loki (Grafana, Explore, Loki data source).
- **Expected:** the first query returns the lines of the step 4 mail, the second the 4xx/5xx responses, the third the smoke test's deliberate 404 request.
- **Evidence:** [evidence.md, 8.](evidence.md#8-searchable-mail-and-web-server-logs)

```text
{service="postfix"} |= "<queue id>"
{service="caddy"} | json | status >= 400
{service="caddy"} |= "corelab-smoke-404"
```

## 6. Firewall: block and control

- **Shows:** every block comes with an allowing control: 443 is open, 80 is closed; 6556 is unreachable from the workstation, but reachable from ext-01 (Checkmk).
- **Expected:** 443 succeeds, 80 and 6556 from the workstation fail; from ext-01 the agent output arrives; in the `status` output the DROP counters grow.
- **Evidence:** [evidence.md, 10.](evidence.md#10-firewall-that-protects-and-isolates-the-container-services)

```bash
nc -z -w3 192.0.2.10 443 && echo "443 open"
nc -z -w3 192.0.2.10 80 || echo "80 closed"
nc -z -w5 192.0.2.10 6556 || echo "6556 closed from here"
ssh core@192.0.2.10 'sudo /usr/local/sbin/corelab-firewall status'
```

From ext-01 (control): `nc 192.0.2.10 6556 | head`.

## 7. Checkmk alert

- **Shows:** the central Checkmk notices, through the local check, when a Compose service stops, and recovers after the restart.
- **Expected:** in the next check cycle the `corelab grafana` service is CRIT, and OK again after the restart.
- **Evidence:** [evidence.md, 9.](evidence.md#9-integration-with-a-central-independent-checkmk)

```bash
ssh core@192.0.2.10 'cd /var/lib/corelab/stack && sudo docker compose stop grafana'
ssh core@192.0.2.10 'sudo /usr/local/lib/check_mk_agent/local/corelab_compose'
ssh core@192.0.2.10 'cd /var/lib/corelab/stack && sudo docker compose start grafana'
```

## 8. Smoke test

- **Shows:** the full end-to-end check in one run, with an allowing control next to every blocking check.
- **Expected:** 15 `PASS` lines, the last line `Result: 15/15 PASS`, exit 0.
- **Evidence:** [install.md, step 11](install.md#11-smoke-test), [evidence.md](evidence.md)

```bash
scripts/smoke-test.sh
```
