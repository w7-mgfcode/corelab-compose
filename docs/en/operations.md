# Backup, updates, secrets

[Magyar](../hu/operations.md) · **English**

This part covers the optional points of the task. Backup and restore have not yet been tried on the lab; the restore time has not been measured.

## Backup

`scripts/backup.sh` runs on the VM, as root (copy it there together with the `images.sh` next to it):

| What it saves | How | Note |
|---|---|---|
| WordPress database | `mariadb-dump --single-transaction` from the running MariaDB | a consistent InnoDB backup; the password passes in an environment variable |
| `wp_html` volume | `tar` from a read-only mount | WordPress core, uploads, themes, plugins |
| `caddy_data` volume | `tar` | **holds the internal CA's private key**; without it a restore would create a new CA, and client trust would have to be set up again |
| `grafana_data` volume | `tar` | Grafana settings and users |

Not saved: the Loki data (treated as rebuildable; retention is 7 days), the Postfix queue (a restored queue could cause duplicate sends), the secrets (their source is the workstation), the host configuration (it can be recreated from Ignition).

The destination is `/var/lib/corelab/backup/<UTC timestamp>/`, root 0700, files 0600, with `SHA256SUMS`. The last 7 backups are kept. Because it is on the same VM, this does not protect against losing the VM or the Proxmox host: **an encrypted copy off the VM is a recommendation**, not part of the script (for example `rsync` or `restic` to separate storage). A Proxmox VM snapshot can be used in addition, but a live copy of the database is not a consistent backup on its own.

## Restore (described, not tried)

On the VM, in `/var/lib/corelab/stack`; `B=/var/lib/corelab/backup/<timestamp>`, and `DEBIAN_IMAGE` from `images.sh`.

1. Stop the stack: `sudo systemctl stop corelab-stack`.
2. Load the volumes back (for all three archives):
   ```bash
   for v in wp_html caddy_data grafana_data; do
     sudo docker run --rm -v "corelab_${v}:/v" -v "$B:/b:ro,z" "$DEBIAN_IMAGE" \
       sh -c "find /v -mindepth 1 -delete && tar -C /v -xzf /b/${v}.tgz"
   done
   ```
3. Load the database back, with only MariaDB running:
   ```bash
   sudo docker compose up -d mariadb        # wait until "healthy"
   sudo docker compose exec -T mariadb sh -c 'MYSQL_PWD="$(cat /run/secrets/db_root_password)" exec mariadb -uroot wordpress' < "$B/wordpress.sql"
   sudo docker compose stop mariadb
   ```
4. Start the usual way: `sudo systemctl start corelab-stack`.
5. Check: `scripts/smoke-test.sh` from the workstation. If `caddy_data` was restored too, the old `root.crt` stays valid.

For a full rebuild, first the new VM (Ignition), then the secrets (`push-secrets.sh`), then the steps above.

## Updates

### Fedora CoreOS (host)

- With the `periodic` strategy, Zincati may reboot only **on Sunday from 03:00 for 60 minutes (UTC)** (`/etc/zincati/config.d/55-updates-strategy.toml`). State: `rpm-ostree status`, `systemctl status zincati`.
- **The Docker CE trap:** Docker CE overrides base packages (`rpm-ostree override`). Before a Fedora major upgrade, check that the Docker repo already supports the new release (`https://download.docker.com/linux/fedora/<version>/`). At the Fedora 40 → 41 upgrade, the overridden packages (because of the new `docker-cli` package) blocked the update. The upstream FCOS guide mentions `rpm-ostree override reset containerd moby-engine runc --uninstall docker-ce` for this; check the exact steps on the current upstream page before updating.
- **The way back:** if something does not work after an update, `sudo rpm-ostree rollback -r` returns to the previous deployment and reboots.
- For a longer outage or test, updates can be paused: `sudo systemctl stop zincati` (start it again afterwards).

### Containers

Every image is pinned by tag + digest, so nothing updates by itself.

1. New tag and digest: `docker buildx imagetools inspect <name>:<tag>` (the "Digest:" line).
2. Replace it in `compose.yaml` (and, where it also appears, in `external/compose.yaml` and the `FROM` line of `config/postfix/Dockerfile`), and in `scripts/images.sh`.
3. `scripts/validate.sh` (the pinning check reports it if the two places differ).
4. Back up on the VM (`backup.sh`), then copy the changed files under `/var/lib/corelab/stack` and run `sudo systemctl restart corelab-stack`.
5. Smoke test. On failure, restore the old tag/digest the same way; after a database migration (a WordPress major version) the way back is the database backup.

**Known limit, WordPress core:** the core lives in the `wp_html` volume. Replacing the image updates only the PHP and Apache layer, not the core in the volume (the official image only copies into an empty volume). WordPress and wpcli sit only on internal networks, so `wp core update` cannot download either, and neither updates nor plugin installs are possible from the UI. This is deliberate, but it means this repo has no ready procedure for core updates. Suggested path: in a maintenance window, back up, temporarily attach wpcli to an egress network, run `wp core update` and `wp core update-db`, then the smoke test.

## Secrets

**Model:** the source of the secrets is the workstation (`~/.config/corelab/secrets`, 0700/0600). They go neither into the repo nor into Ignition; they reach the VM over SSH (`push-secrets.sh`), where they are 0444 files in `/var/lib/corelab/secrets` (root 0700), labelled `container_file_t`. Compose hands them as file-based secrets, under `/run/secrets/<name>`, only to the services that need them; the environment variables hold only the path (`*_FILE`).

**Why 0444:** the containers read with different UIDs (MariaDB 999, WordPress 33, Grafana 472), and a file bind mount bypasses the parent directory's permissions. On the host, the root 0700 directory means only root can reach them.

**Limits:**
- no encryption on the host; anyone with root or Docker API access can read them;
- no automatic rotation;
- the Grafana admin password and the MariaDB passwords are only applied at the first initialisation; replacing the file afterwards changes nothing by itself.

**Manual rotation (example, the WordPress database password):**
1. A new value on the workstation (delete the old file, then `gen-secrets.sh`).
2. In MariaDB: `ALTER USER 'wordpress'@'%' IDENTIFIED BY '<new>';` (`docker compose exec mariadb mariadb -uroot -p`).
3. `push-secrets.sh`, then `sudo systemctl restart corelab-stack`.
4. Smoke test.

The Grafana admin password can be changed in the UI or with `grafana cli admin reset-admin-password`; afterwards update the secret file too, so the two match.
