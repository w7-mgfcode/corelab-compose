# Telepítés lépésről lépésre

**Magyar** · [English](../en/install.md)

Az alábbi lépések a labon még nincsenek végigjátszva; az eredményeket az [evidence.md](evidence.md) rögzíti. A példák címei az RFC 5737 dokumentációs tartományból valók (`192.0.2.10` = app-01, `192.0.2.20` = ext-01, `192.0.2.50` = admin munkaállomás); a saját értékeid csak a nem követett `lab.env`-be kerülnek.

Jelölések: `<VMID>` a Proxmox VM azonosítója, `<STORAGE>` a Proxmox tároló neve (pl. `local-lvm`), `<QCOW>` a letöltött FCOS image fájlneve.

## 0. Előfeltételek

- Munkaállomás: Docker és Docker Compose, `jq`, `openssl`, `ssh`, `nc`, `curl`.
- Proxmox VE root shell (a hoston) és egy `vmbr0` híd a labhálózattal.
- Az ext-01 VM (Mailpit és Checkmk), lásd az 1. lépést.
- Internetkapcsolat az app-01 első bootjához (Docker CE csomagok, kulcs, image-ek, a Postfix image építése).
- Névfeloldás a munkaállomáson, például az `/etc/hosts`-ban:
  ```
  192.0.2.10  app.corelab.test logs.corelab.test
  ```

## 1. ext-01 (külső szereplők)

Kövesd az [external/README.md](../../external/README.md) 1–7. lépését. Eredmény: fut a Mailpit (587, STARTTLS + AUTH) és a Checkmk, és megvan a `tls/relay.crt`, valamint a relay felhasználó és jelszó.

## 2. lab.env

```bash
cp examples/lab.env.example lab.env
$EDITOR lab.env          # your own addresses, the interface name and the public key path
```

A `lab.env` soha nem kerül Gitbe. Az `EXT_IF` értékét az első boot után ellenőrizni kell (`ip -br link`); ha eltér, javítsd és renderelj újra (ilyenkor a VM-et újra kell létrehozni, mert az Ignition csak egyszer fut).

## 3. Ignition

```bash
scripts/validate.sh                 # every line PASS
scripts/render-ignition.sh          # lab.env → build/app-01.ign, prints the sha256
```

## 4. Proxmox: a VM létrehozása

Az FCOS `proxmoxve` image letöltése a munkaállomáson (a `coreos-installer` konténerből fut), majd másolás a Proxmox hostra:

```bash
mkdir -p build/fcos
docker run --rm -v "$PWD/build/fcos":/data -w /data quay.io/coreos/coreos-installer:release \
  download -s stable -p proxmoxve -f qcow2.xz --decompress
scp build/fcos/*.qcow2 root@<PROXMOX>:/var/coreos/images/
scp build/app-01.ign   root@<PROXMOX>:/var/coreos/snippets/app-01.ign
```

(Az `scp` előtt a könyvtáraknak létezniük kell a hoston; lásd lent az első két parancsot.)

A Proxmox hoston, rootként:

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

A statikus cím a Proxmox cloud-init hálózati adatából (`--ipconfig0`) jön, nem a Butane fájlból; DHCP-foglalás is megfelel.

## 5. Első boot

```bash
qm terminal <VMID>        # on the Proxmox host; exit with Ctrl+O
```

Várható menet: az Ignition lefut, a `corelab-docker-ce.service` lecseréli a Moby csomagokat Docker CE-re, majd a gép **magától újraindul**. A második boot után:

```bash
ssh core@192.0.2.10 'rpm -q docker-ce docker-compose-plugin; sudo docker compose version; rpm-ostree status | head -n 8'
ssh core@192.0.2.10 'ip -br link; sudo iptables -S FORWARD | grep DOCKER-USER; readlink -f /usr/local; ls -l /usr/local/sbin/corelab-firewall'
ssh core@192.0.2.10 'systemctl status corelab-firewall-host corelab-firewall-docker --no-pager; systemctl status corelab-stack --no-pager | head -n 5'
```

A `corelab-stack` ezen a ponton „condition failed” állapotú, mert még nincs `.ready` (titkok nélkül nem indul). Az első boot próbák (S1, S3, S4, S5) eredményét az [evidence.md](evidence.md#első-boot-próbák-nyitott-kérdések) rögzíti.

**Ha a tűzfal kizár:** a soros konzol (`qm terminal <VMID>`) mindig elérhető; ott javítható a `/etc/corelab/firewall.env`, majd `sudo systemctl restart corelab-firewall-host`.

## 6. Titkok

```bash
scripts/gen-secrets.sh                       # 4 random secrets under ~/.config/corelab/secrets
cp <relay.crt copied from ext-01> ~/.config/corelab/secrets/relay_ca_cert
printf '[relay.corelab.test]:587 relayuser:%s\n' "<RELAY_PASSWORD>" > ~/.config/corelab/secrets/relay_credentials
chmod 0600 ~/.config/corelab/secrets/*
scripts/push-secrets.sh core@192.0.2.10      # prints names only; .ready goes last
```

A relay jelszavát egy szövegszerkesztővel is beírhatod a fájlba, hogy ne kerüljön a shell előzményeibe.

## 7. A stack indítása

```bash
ssh core@192.0.2.10 'sudo systemctl start corelab-stack && cd /var/lib/corelab/stack && sudo docker compose ps'
```

Az első indítás a VM-en építi a Postfix image-et (internet kell az `apt`-hoz), ezért percekig tarthat. Ezután minden boot és minden `systemctl restart docker` után a sorrend: Docker → `corelab-firewall-docker` → `corelab-stack`.

## 8. WordPress inicializálás

```bash
ssh core@192.0.2.10
cd /var/lib/corelab/stack
sudo docker compose run --rm wpcli sh -c 'wp core install --url=https://app.corelab.test --title=corelab --admin_user=admin --admin_email=admin@corelab.test --admin_password="$(cat /run/secrets/wordpress_admin_password)" --skip-email'
```

## 9. A belső CA exportja és a kliens bizalma

A VM-en (a gyökértanúsítvány helye a Caddy adatvolume-ban a labon ellenőrizendő: S8):

```bash
cd /var/lib/corelab/stack
sudo docker compose exec caddy find /data -name root.crt
sudo docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt /home/core/corelab-root.crt
sudo chown core: /home/core/corelab-root.crt
openssl x509 -in /home/core/corelab-root.crt -noout -fingerprint -sha256
```

A munkaállomáson:

```bash
scp core@192.0.2.10:corelab-root.crt ~/.config/corelab/corelab-root.crt
openssl x509 -in ~/.config/corelab/corelab-root.crt -noout -fingerprint -sha256   # must match the one seen on the VM
curl --cacert ~/.config/corelab/corelab-root.crt -sS -o /dev/null -w '%{http_code}\n' https://app.corelab.test/
```

Csak a `root.crt` hagyja el a VM-et, a CA privát kulcsa soha. A böngésző bizalmát egyetlen bemutató böngészőben, kézzel kell beállítani; a tanúsítvány-ellenőrzést soha nem kapcsoljuk ki.

## 10. Checkmk agent

A Checkmk felületéről letöltött, a szerverrel azonos verziójú `check_mk_agent.linux` telepítése (az agent script alapértelmezett könyvtára a csak olvasható `/usr/lib` alatt van, ezért átírjuk):

```bash
scp check_mk_agent.linux core@192.0.2.10:
ssh core@192.0.2.10 'sed -i "s|^export MK_LIBDIR=.*|export MK_LIBDIR=\"/usr/local/lib/check_mk_agent\"|" check_mk_agent.linux \
  && sudo install -m 0755 check_mk_agent.linux /usr/local/bin/check_mk_agent \
  && sudo systemctl restart check-mk-agent.socket \
  && sudo /usr/local/bin/check_mk_agent | grep -A9 "<<<local"'
```

Az ext-01-ről: `nc 192.0.2.10 6556 | head`, majd a Checkmkben szolgáltatásfelderítés az `app-01` hoston (`corelab …` local check sorok) és a „Check HTTP web service” szabály (S7).

## 11. Füstteszt

A munkaállomáson:

```bash
export VM=core@192.0.2.10 VM_ADDR=192.0.2.10 EXT=192.0.2.20
export LAB_CA_CERT=~/.config/corelab/corelab-root.crt
read -rsp 'Mailpit UI (user:password): ' MAILPIT_UI_AUTH; echo; export MAILPIT_UI_AUTH
scripts/smoke-test.sh          # 15 lines, all PASS; exit 0
```

Utána a kézi próbák és az ismételt füsttesztek (Docker-újraindítás, reboot, tiltott forrás, Checkmk riasztás) az [evidence.md](evidence.md) szerint.

## Későbbi módosítások

Az Ignition csak az első bootkor fut. Ha később változik a `compose.yaml`, a `Caddyfile` vagy valami a `config/` alatt: `scripts/validate.sh`, majd másolás a VM-re (`scp`, és `sudo install` a `/var/lib/corelab/stack` alá), végül `sudo systemctl restart corelab-stack`. A host szintű fájlok (unitok, tűzfal) változásakor a VM újralétrehozása a tiszta út.
