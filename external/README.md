# ext-01 — a „külvilág” a labban

**Magyar** · [English](README.en.md)

> **Ez a VM nem része a megoldásnak.** Azt a két külső szereplőt játssza, amelyet a feladat feltételez: egy hitelesített SMTP relayt és egy központi, független Checkmk szervert. Szándékosan egyszerű és **nem hardenelt** (nincs saját tűzfal, a Mailpit UI és a Checkmk HTTP-n érhető el). Éles környezetben ezek meglévő, külön üzemeltetett szolgáltatások lennének.

| Szolgáltatás | Szerep | Port (ext-01) |
|---|---|---|
| Mailpit | külső SMTP relay: kötelező STARTTLS, SMTP AUTH (bcrypt htpasswd) | 587 (SMTP), 8025 (UI és API, jelszóval) |
| Checkmk Community (korábbi neve: Checkmk Raw) | központi monitoring: agent és aktív HTTPS-ellenőrzés | 8080 (web UI), 8000 (agent receiver) |

A Mailpit azért fut külön VM-en és nem az app-01-en, hogy a relay valóban külső legyen: így a `relay-out` hálózat, a kimenő TLS-ellenőrzés és az SMTP AUTH is ténylegesen kipróbálásra kerül.

## Telepítés

A parancsok az ext-01-en, a repó `external/` könyvtárából futnak.

1. Hozz létre egy Debian 13 VM-et a Proxmoxon (statikus cím, például `192.0.2.20`), és telepítsd rá a Docker CE-t a hivatalos leírás szerint: <https://docs.docker.com/engine/install/debian/>.
2. Készítsd el a relay tanúsítványát: `./make-relay-cert.sh` (kimenet: `tls/relay.crt`, `tls/relay.key`). A kiírt SHA-256 ujjlenyomatot jegyezd fel. A `tls/relay.crt` lesz az app-01 `relay_ca_cert` titka; a `relay.key` soha nem hagyja el az ext-01-et.
3. Hozd létre a jelszófájlokat (bcrypt), a jelszót a parancssor helyett a stdin-en átadva:
   ```bash
   mkdir -p data
   read -rsp 'Relay password: ' P; echo
   printf '%s' "$P" | docker run --rm -i httpd:2.4.71-alpine htpasswd -inB relayuser > data/smtp.htpasswd
   read -rsp 'Mailpit UI password: ' P; echo
   printf '%s' "$P" | docker run --rm -i httpd:2.4.71-alpine htpasswd -inB admin > data/ui.htpasswd
   unset P
   ```
   A relay felhasználó és jelszó a munkaállomáson a `relay_credentials` titokba kerül, ebben a formában: `[relay.corelab.test]:587 relayuser:<JELSZÓ>`.
4. Hozd létre a `checkmk.env` fájlt egyetlen sorral: `CMK_PASSWORD=<cmkadmin jelszó>`, majd `chmod 600 checkmk.env`.
5. Hozd létre az `ext.env` fájlt az app-01 címével (`VM_ADDR=192.0.2.10`), majd indítsd el: `docker compose --env-file ext.env up -d`. A `tls/`, `data/`, `checkmk.env` és `ext.env` a `.gitignore`-ban van.
6. Első belépés a Checkmkbe: `http://<ext-01>:8080/cmk/check_mk/`, felhasználó `cmkadmin`, a jelszó a `checkmk.env`-ből.
7. Vedd fel az `app-01` hostot (Setup > Hosts) a VM címével, „Checkmk agent / API integrations” adatforrással, majd hozz létre egy „Check HTTP web service” szabályt (Setup > Services > HTTP, TCP, Email) a `https://app.corelab.test/` címre, tanúsítvány-ellenőrzéssel. A labgyökér-CA elfogadtatása ellenőrizendő (lásd az [evidence.md](../docs/hu/evidence.md#első-boot-próbák-nyitott-kérdések) S7 sorát).
8. Töltsd le a szerverrel azonos verziójú Linux agent scriptet (`check_mk_agent.linux`) a Checkmk felületéről (Setup > Agents > Linux; a pontos menüút a labon ellenőrizendő), és telepítsd az app-01-re az [install.md](../docs/hu/install.md#10-checkmk-agent) 10. lépése szerint.
9. Ellenőrzés: a Mailpit API jelszóval válaszol (`curl -u admin:<jelszó> http://<ext-01>:8025/api/v1/info`), és a Checkmk szolgáltatásfelderítés megtalálja a `corelab …` local check sorokat.

## Korlátok

- A Mailpit egy tesztfogadó: minden levelet elfogad és megőriz, semmit nem kézbesít tovább. Ez a labon belüli kézbesítést bizonyítja, nem valódi internetes kézbesítést.
- A Mailpit UI és a Checkmk web UI titkosítatlan HTTP; csak a labhálózaton használandó.
- A legacy agent kapcsolat (6556) titkosítatlan; az app-01 tűzfala csak a Checkmk címéről engedi.
