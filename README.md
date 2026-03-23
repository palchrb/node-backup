# node-backup

Lett deploybar backup-bundle for Linux-noder med:

- `restic`
- `rclone` backend
- valgfrie pre-backup hooks
- systemd timer
- webhook-varsling med Bearer auth ved feil

Ingen app-spesifikk logikk er bakt inn. Du velger selv hvilke mapper som skal med, og kan eventuelt kjøre et vilkårlig shell-script/kommando før backup starter.

## Funksjoner

- Backup av valgte mapper via `restic` til `rclone:<remote>:<path>`
- Automatisk `restic init` hvis repo ikke finnes ennå
- Retention (`daily`, `weekly`, `monthly`)
- Valgfri pre-hook via env (`PRE_BACKUP_COMMAND`)
- Statusfil for varsling og enkel helseovervåkning
- Webhook-varsling med `Authorization: Bearer ...` ved feil
- Enkelt å rulle ut på nye noder

## Install

```bash
sudo ./install.sh
sudo nano /etc/default/node-backup
sudo systemctl enable --now node-backup.timer
sudo systemctl enable --now node-backup-notify.timer
```

## Krever

- Linux med `systemd`
- `rclone` konfigurert på hosten
- tilgang til backup-destinasjonen via `rclone`

## Første gangs oppsett

1. Sørg for at `rclone listremotes` viser remote-en du vil bruke.
2. Kjør install.
3. Rediger `/etc/default/node-backup`.
4. Start backup manuelt én gang:

```bash
sudo systemctl start node-backup.service
sudo journalctl -u node-backup.service -n 200 --no-pager
```

## Eksempel på pre-backup hook

I `/etc/default/node-backup`:

```bash
PRE_BACKUP_COMMAND='/usr/local/bin/mysql-dump.sh'
```

eller:

```bash
PRE_BACKUP_COMMAND='docker exec myapp /app/bin/export-data.sh'
```

Hvis kommandoen returnerer ikke-null exit code, stopper backup-jobben og markeres som feil.

## Restore-test

```bash
source /etc/default/node-backup
sudo mkdir -p /restore/test
sudo env \
  RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
  RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  restic restore latest --target /restore/test
```
