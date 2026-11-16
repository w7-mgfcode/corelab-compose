# Ellenőrzés: követelményenként bizonyíték

**Magyar** · [English](../en/evidence.md)

Minden követelménynél: mi bizonyítja, a pontos parancs, és a labon rögzített (rövidített) kimenet. A kimenetekben a lab címei a példacímekre vannak cserélve (`192.0.2.10` = app-01, `192.0.2.20` = ext-01).

**Állapotok**

| Állapot | Jelentés |
|---|---|
| `tervezett` | a fájl vagy eljárás leírva, még nincs ellenőrizve |
| `statikusan ellenőrzött` | a `scripts/validate.sh` az érintett fájlokat a használó eszközzel (rögzített verziójú konténerből) hibátlanul feldolgozta; a labon még nem futott |
| `működik a labon` | a lenti kimenet a labon készült, és a parancs elvárt eredményét mutatja |

Jelenleg egyetlen sor sincs `működik a labon` állapotban: a labos futtatás még hátravan.

## Első boot próbák (nyitott kérdések)

Ezeket az első VM-indításkor kell megválaszolni, mielőtt bármi másra támaszkodnánk.

| # | Kérdés | Parancs | Ha nem teljesül |
|---|---|---|---|
| S1 | A csere telepítette a `docker-ce` és a `docker-compose-plugin` csomagot? | `rpm -q docker-ce docker-compose-plugin; sudo docker compose version` | a `--install` listát kibővíteni: `docker-ce-cli containerd.io` |
| S2 | Címkéz-e SELinuxszal a Docker CE? Olvassa-e az Alloy a megosztott naplókat, a konténerek a titkokat? | `sudo docker info --format '{{.SecurityOptions}}'`; `sudo docker compose logs alloy`; `sudo ausearch -m avc -ts recent` | `daemon.json` `selinux-enabled`, `:z` a megosztott volume-okon; a döntést rögzíteni |
| S3 | Létezik a `DOCKER-USER`, és működik a `FORWARD` ugrás iptables-nft alatt? | `sudo iptables -S FORWARD \| grep DOCKER-USER` | a Docker tűzfal-backendjének ellenőrzése (`docker info`), szükség esetén iptables backend a `daemon.json`-ban |
| S4 | Mi a külső interfész neve? | `ip -br link` | `EXT_IF` javítása a `lab.env`-ben, újrarenderelés |
| S5 | Írható-e a `/usr/local`, és oda írt-e az Ignition? | `readlink -f /usr/local; ls -l /usr/local/sbin/corelab-firewall` | a fájlok áthelyezése `/var/lib/corelab/bin` alá |
| S6 | Működik a Postfix → Mailpit ellenőrzött TLS? | füstteszt: `mail-tls-verified`, `mail-arrived` | SAN és CAfile ellenőrzése, `smtp_tls_loglevel = 2` |
| S7 | Megbízik-e a Checkmk HTTPS-ellenőrzése a labgyökérben? | „Check HTTP web service” szabály tanúsítvány-ellenőrzéssel | ha nem állítható: TCP 443 ellenőrzés és külön tanúsítvány-ellenőrzés, őszintén dokumentálva |
| S8 | Hol van a Caddy `root.crt` a `/data` alatt? | `sudo docker compose exec caddy find /data -name root.crt` | az [install.md](install.md#9-a-belső-ca-exportja-és-a-kliens-bizalma) 9. lépésének javítása |

```text
(a labon kitöltendő)
```

## 1. Fedora CoreOS Proxmox alatt

- **Bizonyíték:** a VM a renderelt Ignitionből jön létre, és FCOS fut rajta; ugyanabból a konfigurációból újra létrehozható.
- **Fájlok:** `butane/app-01.bu`, `scripts/render-ignition.sh`, [install.md](install.md#4-proxmox-a-vm-létrehozása) 4. lépés.
- **Parancs:** `ssh core@192.0.2.10 'cat /etc/os-release | grep -E "^(NAME|VERSION)="; rpm-ostree status | head -n 6'`
- **Állapot:** `statikusan ellenőrzött` (Butane `--strict` renderelés)

```text
(a labon kitöltendő)
```

## 2. Docker CE (nem a beépített Moby)

- **Bizonyíték:** a `moby-engine` eltávolítva, a `docker-ce` telepítve (rpm-ostree override), a második boot után a csere-unit kihagyva.
- **Fájlok:** `systemd/corelab-docker-ce.service`, `butane/docker-ce.repo`.
- **Parancs:** `ssh core@192.0.2.10 'rpm -q docker-ce moby-engine; rpm-ostree status | grep -A3 -i override; sudo docker version --format "{{.Server.Version}}"'`
- **Állapot:** `statikusan ellenőrzött`

```text
(a labon kitöltendő)
```

## 3. Compose stack egy VM-en, klaszter nélkül

- **Bizonyíték:** egyetlen Compose projekt (`corelab`), hét tartósan futó szolgáltatással; csak a systemd indítja, a tűzfal után.
- **Fájlok:** `compose.yaml`, `systemd/corelab-stack.service`.
- **Parancs:** `ssh core@192.0.2.10 'cd /var/lib/corelab/stack && sudo docker compose ps; systemctl list-dependencies corelab-stack --no-pager | head'`
- **Állapot:** `statikusan ellenőrzött` (`docker compose config -q`)

```text
(a labon kitöltendő)
```

## 4. Webes szolgáltatás (WordPress)

- **Bizonyíték:** a WordPress HTTPS-en válaszol, és be lehet lépni; a MariaDB `healthy`.
- **Fájlok:** `compose.yaml` (`wordpress`, `mariadb`, `wpcli`), `config/wordpress/mu-plugins/corelab-smtp.php`.
- **Parancs:** füstteszt `https-app`, `stack-state`; kézi belépés: `https://app.corelab.test/wp-admin/`.
- **Állapot:** `statikusan ellenőrzött` (Compose, `php -l`)

```text
(a labon kitöltendő)
```

## 5. HTTPS-t végződtető reverse proxy (Caddy)

- **Bizonyíték:** a Caddy a 443-on végződteti a TLS-t, és HTTP-n éri el a WordPresst és a Grafanát a belső hálózatokon; a 80-as port zárva.
- **Fájlok:** `Caddyfile`, `compose.yaml` (`caddy`).
- **Parancs:** füstteszt `https-app`, `https-logs-login`, `http-closed`.
- **Állapot:** `statikusan ellenőrzött` (`caddy validate`)

```text
(a labon kitöltendő)
```

## 6. Belső HTTPS belső CA-val és automatikus tanúsítványkiadással

- **Bizonyíték:** a lánc a lab gyökeréig ellenőrizhető; idegen CA-val ugyanaz a kérés tanúsítványhibával bukik (párosított kontroll). A levéltanúsítvány a Caddy belső CA-jától jön, és ugyanazon gyökér alatt megújul.
- **Fájlok:** `Caddyfile` (`tls internal`), [install.md](install.md#9-a-belső-ca-exportja-és-a-kliens-bizalma) 9. lépés.
- **Parancs:** füstteszt `https-app` és `https-untrusted-control`; megújulás: `openssl s_client -connect 192.0.2.10:443 -servername app.corelab.test </dev/null 2>/dev/null | openssl x509 -noout -serial -dates`, két időpontban, változatlan konténer-indítási idővel.
- **Állapot:** `statikusan ellenőrzött`

```text
(a labon kitöltendő)
```

## 7. Postfix SMTP konténer, amelyen át a szolgáltatások levelet küldenek

- **Bizonyíték:** a WordPressből indított levél queue ID-val átmegy a Postfixen, ellenőrzött TLS-sel és hitelesítéssel a relayre jut, és megérkezik a Mailpitbe. Nem megbízható cím a `mail` hálózatról 220-as üdvözlés után `5.7.1` elutasítást kap.
- **Fájlok:** `config/postfix/{Dockerfile,main.cf,entrypoint.sh}`, `compose.yaml` (`postfix`).
- **Parancs:** füstteszt `mail-send`, `mail-queue-id`, `mail-tls-verified`, `mail-arrived`, `relay-refused`.
- **Állapot:** `statikusan ellenőrzött` (image build, `postfix check`, kötelező beállítások)

```text
(a labon kitöltendő)
```

## 8. Kereshető levelezési és webszerver-naplók

- **Bizonyíték:** egy szándékos 404-es kérés és a levél queue ID-ja megtalálható a Lokiban (Grafana Explore); egy soha el nem küldött tokenre 0 találat jön (kontroll).
- **Fájlok:** `config/alloy/config.alloy`, `config/loki/loki.yaml`, `config/grafana/provisioning/datasources/loki.yaml`.
- **Parancs:** füstteszt `logs-http-error`, `logs-queue-id`, `logs-control`; Grafana: `{service="postfix"} |= "<queue id>"`, `{service="caddy"} |= "corelab-smoke-404"`.
- **Állapot:** `statikusan ellenőrzött` (Loki `-verify-config`, `alloy validate`)

```text
(a labon kitöltendő)
```

## 9. Bekötés egy központi, független Checkmk-ba

- **Bizonyíték:** az ext-01 Checkmk agenten (local check) és aktív HTTPS-ellenőrzéssel figyeli az app-01-et. `docker compose stop wordpress` után a szolgáltatás CRIT lesz, `docker compose start wordpress` után OK.
- **Fájlok:** `systemd/check-mk-agent.socket`, `systemd/check-mk-agent@.service`, `monitoring/local/corelab_compose`, `external/compose.yaml`.
- **Parancs:** `ssh core@192.0.2.10 'sudo /usr/local/lib/check_mk_agent/local/corelab_compose'`; a Checkmk felületén a CRIT → OK ciklus képernyőképe vagy eseménylistája.
- **Állapot:** `statikusan ellenőrzött` (shellcheck, Compose)

```text
(a labon kitöltendő)
```

## 10. Tűzfal, amely védi és elkülöníti a konténeres szolgáltatásokat

- **Bizonyíték:** a host rétegben az `INPUT` csak SSH-t (admin), agentet és pinget (Checkmk) enged; a `DOCKER-USER` a publikált 443-at csak a kliens- és a Checkmk-forrásnak, az eredeti célcímre szűrve. A belső portok kívülről zárva; tiltott forrásból a 443 eldobva (kézi próba a Proxmox hostról), a DROP számláló nő. A szabályok Docker-újraindítás és reboot után is a helyükön vannak.
- **Fájlok:** `firewall/*`, `systemd/corelab-firewall-{host,docker}.service`.
- **Parancs:** füstteszt `fw-closed-ports`, `fw-rules`; kézi: a Proxmox hostról `nc -z -w5 192.0.2.10 443` → sikertelen; `ssh core@192.0.2.10 'sudo /usr/local/sbin/corelab-firewall status'` a számlálókkal; `sudo systemctl restart docker` és `sudo systemctl reboot` után a füstteszt újra.
- **Állapot:** `statikusan ellenőrzött` (a kitöltött szabályok valódi betöltése eldobható hálózati névtérben)

```text
(a labon kitöltendő)
```

## 11. Mentés (opcionális)

- **Bizonyíték:** a `backup.sh` létrehozza a dumpot és a volume-archívumokat 0700-as könyvtárban; egy tesztbejegyzés visszaállítása az [operations.md](operations.md#visszaállítás-leírva-nem-kipróbálva) szerint.
- **Fájlok:** `scripts/backup.sh`, `docs/hu/operations.md`.
- **Parancs:** `sudo ./backup.sh && sudo ls -l /var/lib/corelab/backup/*/`
- **Állapot:** `statikusan ellenőrzött` (shellcheck); a visszaállítás leírva, nincs kipróbálva és időmérve

```text
(a labon kitöltendő)
```

## 12. Titokkezelés (opcionális)

- **Bizonyíték:** a titkok nincsenek sem a repóban, sem az Ignitionben; a VM-en root 0700 könyvtárban vannak, és a konténerek `/run/secrets` alatt, fájlként kapják meg őket. `.ready` nélkül a stack nem indul.
- **Fájlok:** `examples/secrets.example`, `scripts/gen-secrets.sh`, `scripts/push-secrets.sh`, `compose.yaml` (`secrets:`).
- **Parancs:** `ssh core@192.0.2.10 'sudo ls -laZ /var/lib/corelab/secrets; sudo docker compose -f /var/lib/corelab/stack/compose.yaml exec mariadb ls -l /run/secrets'`; push előtt: `systemctl status corelab-stack` → „condition failed”.
- **Állapot:** `statikusan ellenőrzött` (shellcheck, Compose)

```text
(a labon kitöltendő)
```

## 13. Frissítési stratégia (opcionális)

- **Bizonyíték:** a Zincati csak a vasárnapi ablakban indít újra; a `rpm-ostree rollback` visszaút; a konténerek tag+digest szerint rögzítettek.
- **Fájlok:** `butane/app-01.bu` (Zincati drop-in), `scripts/images.sh`, `docs/hu/operations.md`.
- **Parancs:** `ssh core@192.0.2.10 'cat /etc/zincati/config.d/55-updates-strategy.toml; systemctl status zincati --no-pager | tail -n 5'`
- **Állapot:** `statikusan ellenőrzött` (Butane renderelés, image-rögzítés ellenőrzése)

```text
(a labon kitöltendő)
```
