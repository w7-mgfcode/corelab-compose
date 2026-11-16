# Mentés, frissítés, titkok

**Magyar** · [English](../en/operations.md)

Ez a rész a feladat opcionális pontjait írja le. A mentés és a visszaállítás a labon még nincs kipróbálva; a visszaállítás ideje nincs mérve.

## Mentés

A `scripts/backup.sh` a VM-en, rootként fut (a mellette lévő `images.sh`-val együtt kell odamásolni):

| Mit ment | Hogyan | Megjegyzés |
|---|---|---|
| WordPress adatbázis | `mariadb-dump --single-transaction` a futó MariaDB-ből | konzisztens InnoDB-mentés; a jelszó környezeti változóban megy át |
| `wp_html` volume | `tar` egy csak olvasható csatolásról | WordPress core, feltöltések, témák, pluginek |
| `caddy_data` volume | `tar` | **benne van a belső CA privát kulcsa**; e nélkül visszaállítás után új CA keletkezne, és a kliensek bizalmát újra be kellene állítani |
| `grafana_data` volume | `tar` | Grafana beállítások és felhasználók |

Nem ment: a Loki adatait (újraépíthetőnek tekintjük; a megőrzés 7 nap), a Postfix queue-t (egy visszaállított queue duplikált küldést okozhatna), a titkokat (a forrásuk a munkaállomáson van), a host konfigurációját (az Ignitionből újra létrehozható).

A cél `/var/lib/corelab/backup/<UTC időbélyeg>/`, root 0700, a fájlok 0600, `SHA256SUMS`-szal. Az utolsó 7 mentés marad meg. Mivel ugyanazon a VM-en van, ez nem véd a VM vagy a Proxmox host elvesztése ellen: **a VM-en kívüli, titkosított másolás ajánlás**, nem része a scriptnek (például `rsync` vagy `restic` egy külön tárolóra). Kiegészítésként Proxmox VM-snapshot is használható, de az adatbázis élő másolata önmagában nem konzisztens mentés.

## Visszaállítás (leírva, nem kipróbálva)

A VM-en, a `/var/lib/corelab/stack` könyvtárban; `B=/var/lib/corelab/backup/<időbélyeg>`, és `DEBIAN_IMAGE` az `images.sh`-ból.

1. A stack leállítása: `sudo systemctl stop corelab-stack`.
2. Volume-ok visszatöltése (mindhárom archívumra):
   ```bash
   for v in wp_html caddy_data grafana_data; do
     sudo docker run --rm -v "corelab_${v}:/v" -v "$B:/b:ro,z" "$DEBIAN_IMAGE" \
       sh -c "find /v -mindepth 1 -delete && tar -C /v -xzf /b/${v}.tgz"
   done
   ```
3. Az adatbázis visszatöltése, csak a MariaDB-t indítva:
   ```bash
   sudo docker compose up -d mariadb        # wait until "healthy"
   sudo docker compose exec -T mariadb sh -c 'MYSQL_PWD="$(cat /run/secrets/db_root_password)" exec mariadb -uroot wordpress' < "$B/wordpress.sql"
   sudo docker compose stop mariadb
   ```
4. Indítás a megszokott úton: `sudo systemctl start corelab-stack`.
5. Ellenőrzés: `scripts/smoke-test.sh` a munkaállomásról. Ha a `caddy_data` is visszakerült, a régi `root.crt` továbbra is érvényes.

Teljes újraépítés esetén előbb az új VM (Ignition), a titkok (`push-secrets.sh`), majd a fenti lépések jönnek.

## Frissítés

### Fedora CoreOS (host)

- A Zincati `periodic` stratégiával csak **vasárnap 03:00-tól 60 percig (UTC)** indíthat újra (`/etc/zincati/config.d/55-updates-strategy.toml`). Állapot: `rpm-ostree status`, `systemctl status zincati`.
- **Docker CE csapda:** a Docker CE alapcsomagokat ír felül (`rpm-ostree override`). Egy Fedora főverzió-váltás előtt ellenőrizni kell, hogy a Docker repó már támogatja-e az új kiadást (`https://download.docker.com/linux/fedora/<verzió>/`). A Fedora 40 → 41 váltásnál a felülírt csomagok (az új `docker-cli` csomag miatt) megakasztották a frissítést. Az upstream FCOS leírás ehhez a `rpm-ostree override reset containerd moby-engine runc --uninstall docker-ce` parancsot említi; a pontos teendőt frissítés előtt az aktuális upstream oldalon kell ellenőrizni.
- **Visszaút:** ha egy frissítés után valami nem működik, `sudo rpm-ostree rollback -r` az előző deploymentre áll vissza és újraindít.
- Egy hosszabb leállás vagy próba idejére a frissítés felfüggeszthető: `sudo systemctl stop zincati` (utána újra el kell indítani).

### Konténerek

Minden image tag + digest szerint rögzített, így semmi sem frissül magától.

1. Új tag és digest: `docker buildx imagetools inspect <név>:<tag>` („Digest:” sor).
2. Csere a `compose.yaml`-ban (és ha ott is szerepel, az `external/compose.yaml`-ban és a `config/postfix/Dockerfile` `FROM` sorában), valamint a `scripts/images.sh`-ban.
3. `scripts/validate.sh` (a rögzítés-ellenőrzés jelzi, ha a két hely eltér).
4. Mentés a VM-en (`backup.sh`), majd a módosított fájlok másolása a `/var/lib/corelab/stack` alá és `sudo systemctl restart corelab-stack`.
5. Füstteszt. Hiba esetén a régi tag/digest visszaállítása ugyanígy; adatbázis-migráció után (WordPress főverzió) a visszaút az adatbázis-mentés.

**Ismert korlát, WordPress core:** a core a `wp_html` volume-ban él. Az image cseréje csak a PHP- és Apache-réteget frissíti, a volume-ban lévő core-t nem (a hivatalos image csak üres volume-ba másol). A WordPress és a wpcli csak belső hálózatokon van, ezért a `wp core update` sem tud letölteni, és a felületről sem lehet frissíteni vagy plugint telepíteni. Ez szándékos, de a core-frissítésnek így nincs kész eljárása ebben a repóban. Javasolt út: karbantartási ablakban mentés, a wpcli ideiglenes csatlakoztatása egy kimenő hálózathoz, `wp core update` és `wp core update-db`, majd füstteszt.

## Titkok

**Modell:** a titkok forrása a munkaállomás (`~/.config/corelab/secrets`, 0700/0600). Sem a repóba, sem az Ignitionbe nem kerülnek; SSH-n jutnak a VM-re (`push-secrets.sh`), ahol a `/var/lib/corelab/secrets` könyvtárban (root 0700) 0444-es fájlok, `container_file_t` címkével. A Compose fájl alapú secretként, `/run/secrets/<név>` alatt adja őket csak azoknak a szolgáltatásoknak, amelyeknek kellenek; a környezeti változókban csak az elérési út szerepel (`*_FILE`).

**Miért 0444:** a konténerek eltérő UID-dal olvasnak (MariaDB 999, WordPress 33, Grafana 472), és a fájl-bind-mount megkerüli a szülőkönyvtár jogait. A hoston a 0700-as root könyvtár miatt csak root éri el őket.

**Korlátok:**
- nincs titkosítás a hoston; aki root vagy Docker API hozzáféréssel bír, olvashatja őket;
- nincs automatikus rotáció;
- a Grafana adminjelszó és a MariaDB jelszavak csak az első inicializáláskor kerülnek be; utána a fájl cseréje önmagában nem változtat semmit.

**Kézi rotáció (példa, WordPress adatbázis-jelszó):**
1. Új érték a munkaállomáson (a régi fájl törlése, majd `gen-secrets.sh`).
2. A MariaDB-ben: `ALTER USER 'wordpress'@'%' IDENTIFIED BY '<új>';` (`docker compose exec mariadb mariadb -uroot -p`).
3. `push-secrets.sh`, majd `sudo systemctl restart corelab-stack`.
4. Füstteszt.

A Grafana adminjelszava a felületen vagy a `grafana cli admin reset-admin-password` paranccsal cserélhető, utána a titokfájlt is frissíteni kell, hogy a kettő egyezzen.
