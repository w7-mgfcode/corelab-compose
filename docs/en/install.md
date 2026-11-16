# Step-by-step installation

[Magyar](../hu/install.md) · **English**

These steps have not yet been played through on the lab; [evidence.md](evidence.md) records the results. The example addresses come from the RFC 5737 documentation range (`192.0.2.10` = app-01, `192.0.2.20` = ext-01, `192.0.2.50` = admin workstation); your own values go only into the untracked `lab.env`.

Notation: `<VMID>` is the Proxmox VM ID, `<STORAGE>` the Proxmox storage name (e.g. `local-lvm`), `<QCOW>` the file name of the downloaded FCOS image.

## 0. Prerequisites

- Workstation: Docker and Docker Compose, `jq`, `openssl`, `ssh`, `nc`, `curl`.
- A Proxmox VE root shell (on the host) and a `vmbr0` bridge to the lab network.
- The ext-01 VM (Mailpit and Checkmk), see step 1.
- Internet access for app-01's first boot (Docker CE packages, key, images, building the Postfix image).
- Name resolution on the workstation, for example in `/etc/hosts`:
  ```
  192.0.2.10  app.corelab.test logs.corelab.test
  ```

## 1. ext-01 (external actors)

Follow steps 1–7 of [external/README.en.md](../../external/README.en.md). Result: Mailpit (587, STARTTLS + AUTH) and Checkmk are running, and you have `tls/relay.crt` plus the relay user and password.

## 2. lab.env

```bash
cp examples/lab.env.example lab.env
$EDITOR lab.env          # your own addresses, the interface name and the public key path
```

`lab.env` never goes into Git. Check the value of `EXT_IF` after the first boot (`ip -br link`); if it differs, fix it and render again (the VM must then be recreated, because Ignition runs only once).

## 3. Ignition

```bash
scripts/validate.sh                 # every line PASS
scripts/render-ignition.sh          # lab.env → build/app-01.ign, prints the sha256
```

## 4. Proxmox: create the VM

Download the FCOS `proxmoxve` image on the workstation (`coreos-installer` runs from a container), then copy it to the Proxmox host:

```bash
mkdir -p build/fcos
docker run --rm -v "$PWD/build/fcos":/data -w /data quay.io/coreos/coreos-installer:release \
  download -s stable -p proxmoxve -f qcow2.xz --decompress
scp build/fcos/*.qcow2 root@<PROXMOX>:/var/coreos/images/
scp build/app-01.ign   root@<PROXMOX>:/var/coreos/snippets/app-01.ign
```

(The directories must exist on the host before the `scp`; see the first two commands below.)

On the Proxmox host, as root:

```bash
mkdir -p /var/coreos/images /var/coreos/snippets
pvesm add dir coreos --path /var/coreos --content images,snippets

qm create <VMID> --name app-01 --cores 2 --memory 4096 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci
qm set <VMID> --scsi0 "<STORAGE>:0,import-from=/var/coreos/images/<QCOW>"
qm resize <VMID> scsi0 +30G
qm set <VMID> --ide2 <STORAGE>:cloudinit
qm set <VMID> --boot order=scsi0
qm set <VMID> --serial0 socket --vga serial0
qm set <VMID> --cicustom vendor=coreos:snippets/app-01.ign
qm set <VMID> --ciupgrade 0
qm set <VMID> --ipconfig0 ip=192.0.2.10/24,gw=192.0.2.1
qm start <VMID>
```

The static address comes from the Proxmox cloud-init network data (`--ipconfig0`), not from the Butane file; a DHCP reservation works too.

## 5. First boot

```bash
qm terminal <VMID>        # on the Proxmox host; exit with Ctrl+O
```

Expected sequence: Ignition runs, `corelab-docker-ce.service` swaps the Moby packages for Docker CE, and the machine **reboots by itself**. After the second boot:

```bash
ssh core@192.0.2.10 'rpm -q docker-ce docker-compose-plugin; sudo docker compose version; rpm-ostree status | head -n 8'
ssh core@192.0.2.10 'ip -br link; sudo iptables -S FORWARD | grep DOCKER-USER; readlink -f /usr/local; ls -l /usr/local/sbin/corelab-firewall'
ssh core@192.0.2.10 'systemctl status corelab-firewall-host corelab-firewall-docker --no-pager; systemctl status corelab-stack --no-pager | head -n 5'
```

At this point `corelab-stack` shows "condition failed", because there is no `.ready` yet (it does not start without the secrets). [evidence.md](evidence.md#first-boot-probes-open-questions) records the results of the first-boot probes (S1, S3, S4, S5).

**If the firewall locks you out:** the serial console (`qm terminal <VMID>`) is always available; fix `/etc/corelab/firewall.env` there, then run `sudo systemctl restart corelab-firewall-host`.

## 6. Secrets

```bash
scripts/gen-secrets.sh                       # 4 random secrets under ~/.config/corelab/secrets
cp <relay.crt copied from ext-01> ~/.config/corelab/secrets/relay_ca_cert
printf '[relay.corelab.test]:587 relayuser:%s\n' "<RELAY_PASSWORD>" > ~/.config/corelab/secrets/relay_credentials
chmod 0600 ~/.config/corelab/secrets/*
scripts/push-secrets.sh core@192.0.2.10      # prints names only; .ready goes last
```

You can also type the relay password into the file with a text editor, so it stays out of the shell history.

## 7. Start the stack

```bash
ssh core@192.0.2.10 'sudo systemctl start corelab-stack && cd /var/lib/corelab/stack && sudo docker compose ps'
```

The first start builds the Postfix image on the VM (`apt` needs internet), so it can take minutes. From then on, after every boot and every `systemctl restart docker`, the order is: Docker → `corelab-firewall-docker` → `corelab-stack`.

## 8. Initialise WordPress

```bash
ssh core@192.0.2.10
cd /var/lib/corelab/stack
sudo docker compose run --rm wpcli sh -c 'wp core install --url=https://app.corelab.test --title=corelab --admin_user=admin --admin_email=admin@corelab.test --admin_password="$(cat /run/secrets/wordpress_admin_password)" --skip-email'
```

## 9. Export the internal CA and trust it on the client

On the VM (the location of the root certificate in Caddy's data volume is to be checked on the lab: S8):

```bash
cd /var/lib/corelab/stack
sudo docker compose exec caddy find /data -name root.crt
sudo docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt /home/core/corelab-root.crt
sudo chown core: /home/core/corelab-root.crt
openssl x509 -in /home/core/corelab-root.crt -noout -fingerprint -sha256
```

On the workstation:

```bash
scp core@192.0.2.10:corelab-root.crt ~/.config/corelab/corelab-root.crt
openssl x509 -in ~/.config/corelab/corelab-root.crt -noout -fingerprint -sha256   # must match the one seen on the VM
curl --cacert ~/.config/corelab/corelab-root.crt -sS -o /dev/null -w '%{http_code}\n' https://app.corelab.test/
```

Only `root.crt` leaves the VM, never the CA's private key. Browser trust is set up by hand, in a single demo browser; certificate verification is never turned off.

## 10. Checkmk agent

Install `check_mk_agent.linux`, downloaded from the Checkmk UI in the same version as the server (the agent script's default library directory is under the read-only `/usr/lib`, so it is rewritten):

```bash
scp check_mk_agent.linux core@192.0.2.10:
ssh core@192.0.2.10 'sed -i "s|^export MK_LIBDIR=.*|export MK_LIBDIR=\"/usr/local/lib/check_mk_agent\"|" check_mk_agent.linux \
  && sudo install -m 0755 check_mk_agent.linux /usr/local/bin/check_mk_agent \
  && sudo systemctl restart check-mk-agent.socket \
  && sudo /usr/local/bin/check_mk_agent | grep -A9 "<<<local"'
```

From ext-01: `nc 192.0.2.10 6556 | head`, then in Checkmk a service discovery on the `app-01` host (the `corelab …` local check lines) and the "Check HTTP web service" rule (S7).

## 11. Smoke test

On the workstation:

```bash
export VM=core@192.0.2.10 VM_ADDR=192.0.2.10 EXT=192.0.2.20
export LAB_CA_CERT=~/.config/corelab/corelab-root.crt
read -rsp 'Mailpit UI (user:password): ' MAILPIT_UI_AUTH; echo; export MAILPIT_UI_AUTH
scripts/smoke-test.sh          # 15 lines, all PASS; exit 0
```

Then the manual probes and the repeated smoke tests (Docker restart, reboot, forbidden source, Checkmk alert), as described in [evidence.md](evidence.md).

## Later changes

Ignition runs only on the first boot. If `compose.yaml`, the `Caddyfile` or anything under `config/` changes later: `scripts/validate.sh`, then copy to the VM (`scp`, and `sudo install` under `/var/lib/corelab/stack`), and finally `sudo systemctl restart corelab-stack`. When host-level files (units, firewall) change, recreating the VM is the clean way.
