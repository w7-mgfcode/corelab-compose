# Evidence: proof per requirement

[Magyar](../hu/evidence.md) · **English**

For every requirement: what proves it, the exact command, and the (shortened) output recorded on the lab. In the outputs, the lab addresses are replaced with the example addresses (`192.0.2.10` = app-01, `192.0.2.20` = ext-01).

**Status words**

| Status | Meaning |
|---|---|
| `planned` | the file or procedure is written down, not yet checked |
| `statically checked` | `scripts/validate.sh` processed the affected files without error, with the tool that uses them (from a pinned container); not yet run on the lab |
| `works in the lab` | the output below was made on the lab and shows the command's expected result |

At the moment no row is `works in the lab`: the lab run is still ahead.

## First-boot probes (open questions)

These must be answered on the first VM start, before anything else relies on them.

| # | Question | Command | If it does not hold |
|---|---|---|---|
| S1 | Did the swap install the `docker-ce` and `docker-compose-plugin` packages? | `rpm -q docker-ce docker-compose-plugin; sudo docker compose version` | extend the `--install` list: `docker-ce-cli containerd.io` |
| S2 | Does Docker CE label with SELinux? Can Alloy read the shared logs, and the containers the secrets? | `sudo docker info --format '{{.SecurityOptions}}'`; `sudo docker compose logs alloy`; `sudo ausearch -m avc -ts recent` | `daemon.json` `selinux-enabled`, `:z` on the shared volumes; record the decision |
| S3 | Does `DOCKER-USER` exist, and does the `FORWARD` jump work under iptables-nft? | `sudo iptables -S FORWARD \| grep DOCKER-USER` | check Docker's firewall backend (`docker info`); if needed, the iptables backend in `daemon.json` |
| S4 | What is the name of the external interface? | `ip -br link` | fix `EXT_IF` in `lab.env`, render again |
| S5 | Is `/usr/local` writable, and did Ignition write there? | `readlink -f /usr/local; ls -l /usr/local/sbin/corelab-firewall` | move the files under `/var/lib/corelab/bin` |
| S6 | Does verified TLS from Postfix to Mailpit work? | smoke test: `mail-tls-verified`, `mail-arrived` | check the SAN and the CAfile, `smtp_tls_loglevel = 2` |
| S7 | Does Checkmk's HTTPS check trust the lab root? | the "Check HTTP web service" rule with certificate verification | if it cannot be set: a TCP 443 check plus a separate certificate check, documented honestly |
| S8 | Where is Caddy's `root.crt` under `/data`? | `sudo docker compose exec caddy find /data -name root.crt` | fix step 9 of [install.md](install.md#9-export-the-internal-ca-and-trust-it-on-the-client) |

```text
(to be filled in on the lab)
```

## 1. Fedora CoreOS under Proxmox

- **Evidence:** the VM is created from the rendered Ignition and runs FCOS; it can be recreated from the same config.
- **Files:** `butane/app-01.bu`, `scripts/render-ignition.sh`, [install.md](install.md#4-proxmox-create-the-vm) step 4.
- **Command:** `ssh core@192.0.2.10 'cat /etc/os-release | grep -E "^(NAME|VERSION)="; rpm-ostree status | head -n 6'`
- **Status:** `statically checked` (Butane `--strict` rendering)

```text
(to be filled in on the lab)
```

## 2. Docker CE (not the built-in Moby)

- **Evidence:** `moby-engine` is removed and `docker-ce` is installed (rpm-ostree override); after the second boot the swap unit is skipped.
- **Files:** `systemd/corelab-docker-ce.service`, `butane/docker-ce.repo`.
- **Command:** `ssh core@192.0.2.10 'rpm -q docker-ce moby-engine; rpm-ostree status | grep -A3 -i override; sudo docker version --format "{{.Server.Version}}"'`
- **Status:** `statically checked`

```text
(to be filled in on the lab)
```

## 3. Compose stack on one VM, no cluster

- **Evidence:** a single Compose project (`corelab`) with seven long-running services; only systemd starts it, after the firewall.
- **Files:** `compose.yaml`, `systemd/corelab-stack.service`.
- **Command:** `ssh core@192.0.2.10 'cd /var/lib/corelab/stack && sudo docker compose ps; systemctl list-dependencies corelab-stack --no-pager | head'`
- **Status:** `statically checked` (`docker compose config -q`)

```text
(to be filled in on the lab)
```

## 4. Web service (WordPress)

- **Evidence:** WordPress answers over HTTPS, and you can log in; MariaDB is `healthy`.
- **Files:** `compose.yaml` (`wordpress`, `mariadb`, `wpcli`), `config/wordpress/mu-plugins/corelab-smtp.php`.
- **Command:** smoke test `https-app`, `stack-state`; manual login: `https://app.corelab.test/wp-admin/`.
- **Status:** `statically checked` (Compose, `php -l`)

```text
(to be filled in on the lab)
```

## 5. HTTPS-terminating reverse proxy (Caddy)

- **Evidence:** Caddy terminates TLS on 443 and reaches WordPress and Grafana over HTTP on the internal networks; port 80 is closed.
- **Files:** `Caddyfile`, `compose.yaml` (`caddy`).
- **Command:** smoke test `https-app`, `https-logs-login`, `http-closed`.
- **Status:** `statically checked` (`caddy validate`)

```text
(to be filled in on the lab)
```

## 6. Internal HTTPS with an internal CA and automatic certificate issuance

- **Evidence:** the chain verifies up to the lab root; with a foreign CA the same request fails with a certificate error (paired control). The leaf certificate comes from Caddy's internal CA and is renewed under the same root.
- **Files:** `Caddyfile` (`tls internal`), [install.md](install.md#9-export-the-internal-ca-and-trust-it-on-the-client) step 9.
- **Command:** smoke test `https-app` and `https-untrusted-control`; renewal: `openssl s_client -connect 192.0.2.10:443 -servername app.corelab.test </dev/null 2>/dev/null | openssl x509 -noout -serial -dates`, at two points in time, with an unchanged container start time.
- **Status:** `statically checked`

```text
(to be filled in on the lab)
```

## 7. Postfix SMTP container that the services send mail through

- **Evidence:** a mail sent from WordPress passes Postfix with a queue ID, reaches the relay with verified TLS and authentication, and arrives in Mailpit. An untrusted address on the `mail` network gets a `5.7.1` rejection after the 220 greeting.
- **Files:** `config/postfix/{Dockerfile,main.cf,entrypoint.sh}`, `compose.yaml` (`postfix`).
- **Command:** smoke test `mail-send`, `mail-queue-id`, `mail-tls-verified`, `mail-arrived`, `relay-refused`.
- **Status:** `statically checked` (image build, `postfix check`, required settings)

```text
(to be filled in on the lab)
```

## 8. Searchable mail and web server logs

- **Evidence:** a deliberate 404 request and the mail's queue ID can be found in Loki (Grafana Explore); a token that was never sent returns 0 hits (control).
- **Files:** `config/alloy/config.alloy`, `config/loki/loki.yaml`, `config/grafana/provisioning/datasources/loki.yaml`.
- **Command:** smoke test `logs-http-error`, `logs-queue-id`, `logs-control`; Grafana: `{service="postfix"} |= "<queue id>"`, `{service="caddy"} |= "corelab-smoke-404"`.
- **Status:** `statically checked` (Loki `-verify-config`, `alloy validate`)

```text
(to be filled in on the lab)
```

## 9. Integration with a central, independent Checkmk

- **Evidence:** the Checkmk on ext-01 monitors app-01 through the agent (local check) and an active HTTPS check. After `docker compose stop wordpress` the service turns CRIT, after `docker compose start wordpress` it is OK again.
- **Files:** `systemd/check-mk-agent.socket`, `systemd/check-mk-agent@.service`, `monitoring/local/corelab_compose`, `external/compose.yaml`.
- **Command:** `ssh core@192.0.2.10 'sudo /usr/local/lib/check_mk_agent/local/corelab_compose'`; a screenshot or the event list of the CRIT → OK cycle in the Checkmk UI.
- **Status:** `statically checked` (shellcheck, Compose)

```text
(to be filled in on the lab)
```

## 10. Firewall that protects and isolates the container services

- **Evidence:** in the host layer, `INPUT` allows only SSH (admin), the agent and ping (Checkmk); `DOCKER-USER` allows the published 443 only to the client and Checkmk sources, matched on the original destination. The internal ports are closed from outside; from a forbidden source 443 is dropped (manual test from the Proxmox host), and the DROP counter grows. The rules are back in place after a Docker restart and after a reboot.
- **Files:** `firewall/*`, `systemd/corelab-firewall-{host,docker}.service`.
- **Command:** smoke test `fw-closed-ports`, `fw-rules`; manual: from the Proxmox host `nc -z -w5 192.0.2.10 443` → fails; `ssh core@192.0.2.10 'sudo /usr/local/sbin/corelab-firewall status'` with the counters; the smoke test again after `sudo systemctl restart docker` and after `sudo systemctl reboot`.
- **Status:** `statically checked` (a real load of the filled-in rules in a throwaway network namespace)

```text
(to be filled in on the lab)
```

## 11. Backup (optional)

- **Evidence:** `backup.sh` creates the dump and the volume archives in a 0700 directory; a test entry is restored as described in [operations.md](operations.md#restore-described-not-tried).
- **Files:** `scripts/backup.sh`, `docs/en/operations.md`.
- **Command:** `sudo ./backup.sh && sudo ls -l /var/lib/corelab/backup/*/`
- **Status:** `statically checked` (shellcheck); the restore is described, not tried and not timed

```text
(to be filled in on the lab)
```

## 12. Secret management (optional)

- **Evidence:** the secrets are neither in the repo nor in Ignition; on the VM they sit in a root 0700 directory, and the containers receive them as files under `/run/secrets`. Without `.ready` the stack does not start.
- **Files:** `examples/secrets.example`, `scripts/gen-secrets.sh`, `scripts/push-secrets.sh`, `compose.yaml` (`secrets:`).
- **Command:** `ssh core@192.0.2.10 'sudo ls -laZ /var/lib/corelab/secrets; sudo docker compose -f /var/lib/corelab/stack/compose.yaml exec mariadb ls -l /run/secrets'`; before the push: `systemctl status corelab-stack` → "condition failed".
- **Status:** `statically checked` (shellcheck, Compose)

```text
(to be filled in on the lab)
```

## 13. Update strategy (optional)

- **Evidence:** Zincati reboots only in the Sunday window; `rpm-ostree rollback` is the way back; the containers are pinned by tag+digest.
- **Files:** `butane/app-01.bu` (Zincati drop-in), `scripts/images.sh`, `docs/en/operations.md`.
- **Command:** `ssh core@192.0.2.10 'cat /etc/zincati/config.d/55-updates-strategy.toml; systemctl status zincati --no-pager | tail -n 5'`
- **Status:** `statically checked` (Butane rendering, image pinning check)

```text
(to be filled in on the lab)
```
