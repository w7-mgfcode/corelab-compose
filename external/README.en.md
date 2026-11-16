# ext-01 — the "outside world" in the lab

[Magyar](README.md) · **English**

> **This VM is not part of the solution.** It plays the two external actors that the task assumes: an authenticated SMTP relay and a central, independent Checkmk server. It is deliberately simple and **not hardened** (no firewall of its own; the Mailpit UI and Checkmk are reachable over HTTP). In production these would be existing, separately operated services.

| Service | Role | Port (ext-01) |
|---|---|---|
| Mailpit | external SMTP relay: mandatory STARTTLS, SMTP AUTH (bcrypt htpasswd) | 587 (SMTP), 8025 (UI and API, with a password) |
| Checkmk Community (formerly: Checkmk Raw) | central monitoring: agent and active HTTPS check | 8080 (web UI), 8000 (agent receiver) |

Mailpit runs on a separate VM and not on app-01 so that the relay is really external: this way the `relay-out` network, outbound TLS verification and SMTP AUTH are all exercised for real.

## Installation

The commands run on ext-01, from the repo's `external/` directory.

1. Create a Debian 13 VM on Proxmox (static address, for example `192.0.2.20`), and install Docker CE on it following the official guide: <https://docs.docker.com/engine/install/debian/>.
2. Create the relay certificate: `./make-relay-cert.sh` (output: `tls/relay.crt`, `tls/relay.key`). Note the SHA-256 fingerprint it prints. `tls/relay.crt` becomes app-01's `relay_ca_cert` secret; `relay.key` never leaves ext-01.
3. Create the password files (bcrypt), passing the password on stdin instead of the command line:
   ```bash
   mkdir -p data
   read -rsp 'Relay password: ' P; echo
   printf '%s' "$P" | docker run --rm -i httpd:2.4.71-alpine htpasswd -inB relayuser > data/smtp.htpasswd
   read -rsp 'Mailpit UI password: ' P; echo
   printf '%s' "$P" | docker run --rm -i httpd:2.4.71-alpine htpasswd -inB admin > data/ui.htpasswd
   unset P
   ```
   On the workstation, the relay user and password go into the `relay_credentials` secret, in this form: `[relay.corelab.test]:587 relayuser:<PASSWORD>`.
4. Create the `checkmk.env` file with a single line: `CMK_PASSWORD=<cmkadmin password>`, then `chmod 600 checkmk.env`.
5. Create the `ext.env` file with app-01's address (`VM_ADDR=192.0.2.10`), then start it: `docker compose --env-file ext.env up -d`. `tls/`, `data/`, `checkmk.env` and `ext.env` are in `.gitignore`.
6. First login to Checkmk: `http://<ext-01>:8080/cmk/check_mk/`, user `cmkadmin`, the password from `checkmk.env`.
7. Add the `app-01` host (Setup > Hosts) with the VM's address and the "Checkmk agent / API integrations" data source, then create a "Check HTTP web service" rule (Setup > Services > HTTP, TCP, Email) for `https://app.corelab.test/`, with certificate verification. Whether the lab root CA is accepted is still to be checked (see row S7 of [evidence.md](../docs/en/evidence.md#first-boot-probes-open-questions)).
8. Download the Linux agent script (`check_mk_agent.linux`) in the same version as the server from the Checkmk UI (Setup > Agents > Linux; the exact menu path is to be checked on the lab), and install it on app-01 as in step 10 of [install.md](../docs/en/install.md#10-checkmk-agent).
9. Check: the Mailpit API answers with a password (`curl -u admin:<password> http://<ext-01>:8025/api/v1/info`), and Checkmk's service discovery finds the `corelab …` local check lines.

## Limits

- Mailpit is a test receiver: it accepts and keeps every mail and delivers nothing further. This proves delivery inside the lab, not real delivery on the internet.
- The Mailpit UI and the Checkmk web UI are unencrypted HTTP; use them only on the lab network.
- The legacy agent connection (6556) is unencrypted; app-01's firewall allows it only from the Checkmk address.
