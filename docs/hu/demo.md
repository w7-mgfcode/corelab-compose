# Bemutató: 10 perc élőben

**Magyar** · [English](../en/demo.md)

Forgatókönyv egy élő hívásra: nyolc lépés, mindegyiknél mit mutatunk, a pontos parancs vagy cím, és az elvárt eredmény egy sorban. A lépések a telepített labot feltételezik ([install.md](install.md), 0–11. lépés); a hozzájuk tartozó rögzített kimenetek helye az [evidence.md](evidence.md).

Előkészítés a munkaállomáson: a `/etc/hosts` bejegyzés (`192.0.2.10  app.corelab.test logs.corelab.test`), az exportált gyökértanúsítvány a `~/.config/corelab/corelab-root.crt` helyen, és két nyitott böngészőfül: Grafana (`https://logs.corelab.test/`) és a Mailpit UI (`http://192.0.2.20:8025/`).

| Lépés | Téma | Idő |
|---|---|---|
| 1 | statikus ellenőrzés | 1 perc |
| 2 | Fedora CoreOS és Docker CE | 1 perc |
| 3 | HTTPS a belső CA-val | 1 perc |
| 4 | levél a WordPressből a Mailpitig | 1,5 perc |
| 5 | naplókeresés a Grafanában | 1,5 perc |
| 6 | tűzfal: tiltás és kontroll | 1,5 perc |
| 7 | Checkmk riasztás | 1,5 perc |
| 8 | füstteszt | 1 perc |

## 1. Statikus ellenőrzés

- **Mit mutat:** minden konfigurációs fájlt az a rögzített verziójú eszköz dolgoz fel, amelyik használja; ugyanez fut a CI-ban is.
- **Elvárt:** 16 `PASS` sor, az utolsó sor `Result: all checks PASS`.
- **Bizonyíték:** [evidence.md](evidence.md) (állapotok), a README CI-jelvénye.

```bash
scripts/validate.sh
```

## 2. Fedora CoreOS és Docker CE

- **Mit mutat:** a VM FCOS-t futtat, és a beépített Moby helyett Docker CE van rajta (`rpm-ostree override`).
- **Elvárt:** a `docker-ce` csomag verziója, az `rpm-ostree status` pedig a felülírt (eltávolított) Moby-csomagokat és a rétegzett `docker-ce`-t mutatja.
- **Bizonyíték:** [evidence.md, 1.](evidence.md#1-fedora-coreos-proxmox-alatt) és [2.](evidence.md#2-docker-ce-nem-a-beépített-moby)

```bash
ssh core@192.0.2.10 'rpm -q docker-ce; rpm-ostree status | head -n 6'
```

## 3. HTTPS a belső CA-val

- **Mit mutat:** a Caddy a belső CA-val kiadott tanúsítvánnyal szolgál ki, és a kliens a labgyökérrel ellenőrzi; a tanúsítvány-ellenőrzés be van kapcsolva.
- **Elvárt:** egy `HTTP/2` státuszsor (200 vagy átirányítás), tanúsítványhiba nélkül.
- **Bizonyíték:** [evidence.md, 5.](evidence.md#5-https-t-végződtető-reverse-proxy-caddy) és [6.](evidence.md#6-belső-https-belső-ca-val-és-automatikus-tanúsítványkiadással)

```bash
curl --cacert ~/.config/corelab/corelab-root.crt -sI https://app.corelab.test/
```

## 4. Levél a WordPressből a Mailpitig

- **Mit mutat:** a WordPress (ugyanazzal a mu-pluginnel, a `wpcli`-n át) levelet küld; a Postfix ellenőrzött TLS-sel és hitelesítéssel adja tovább a relaynek.
- **Elvárt:** a parancs kilépési kódja 0, a levél a Mailpit UI-ban `corelab demo` tárggyal megjelenik, a Postfix naplóban `status=sent` és egy queue ID látszik.
- **Bizonyíték:** [evidence.md, 7.](evidence.md#7-postfix-smtp-konténer-amelyen-át-a-szolgáltatások-levelet-küldenek)

```bash
ssh core@192.0.2.10
cd /var/lib/corelab/stack
sudo docker compose run --rm -T wpcli wp eval 'exit(wp_mail("demo@example.test", "corelab demo", "corelab demo") ? 0 : 1);'
sudo docker compose exec -T postfix tail -n 20 /var/log/postfix/mail.log
```

## 5. Naplókeresés a Grafanában

- **Mit mutat:** a levél queue ID-ja és a webes hibák kereshetők a Lokiban (Grafana, Explore, Loki adatforrás).
- **Elvárt:** az első lekérdezés a 4. lépés levelének sorait adja, a második a 4xx/5xx válaszokat, a harmadik a füstteszt szándékos 404-es kérését.
- **Bizonyíték:** [evidence.md, 8.](evidence.md#8-kereshető-levelezési-és-webszerver-naplók)

```text
{service="postfix"} |= "<queue id>"
{service="caddy"} | json | status >= 400
{service="caddy"} |= "corelab-smoke-404"
```

## 6. Tűzfal: tiltás és kontroll

- **Mit mutat:** a tiltások mellett mindig van engedélyező kontroll: a 443 nyitva, a 80 zárva; a 6556 a munkaállomásról nem érhető el, az ext-01-ről (Checkmk) igen.
- **Elvárt:** a 443 sikeres, a 80 és a munkaállomásról a 6556 sikertelen; az ext-01-ről az agent kimenete jön; a `status` kimenetben a DROP-számlálók nőnek.
- **Bizonyíték:** [evidence.md, 10.](evidence.md#10-tűzfal-amely-védi-és-elkülöníti-a-konténeres-szolgáltatásokat)

```bash
nc -z -w3 192.0.2.10 443 && echo "443 open"
nc -z -w3 192.0.2.10 80 || echo "80 closed"
nc -z -w5 192.0.2.10 6556 || echo "6556 closed from here"
ssh core@192.0.2.10 'sudo /usr/local/sbin/corelab-firewall status'
```

Az ext-01-ről (kontroll): `nc 192.0.2.10 6556 | head`.

## 7. Checkmk riasztás

- **Mit mutat:** a központi Checkmk a local checken át észreveszi, ha egy Compose szolgáltatás leáll, és az újraindítás után visszaáll.
- **Elvárt:** a következő ellenőrzési ciklusban a `corelab grafana` szolgáltatás CRIT, az újraindítás után OK.
- **Bizonyíték:** [evidence.md, 9.](evidence.md#9-bekötés-egy-központi-független-checkmk-ba)

```bash
ssh core@192.0.2.10 'cd /var/lib/corelab/stack && sudo docker compose stop grafana'
ssh core@192.0.2.10 'sudo /usr/local/lib/check_mk_agent/local/corelab_compose'
ssh core@192.0.2.10 'cd /var/lib/corelab/stack && sudo docker compose start grafana'
```

## 8. Füstteszt

- **Mit mutat:** a teljes végpontok közötti ellenőrzés egy futásban, minden tiltó ellenőrzés mellett engedélyező kontrollal.
- **Elvárt:** 15 `PASS` sor, az utolsó sor `Result: 15/15 PASS`, exit 0.
- **Bizonyíték:** [install.md, 11. lépés](install.md#11-füstteszt), [evidence.md](evidence.md)

```bash
scripts/smoke-test.sh
```
