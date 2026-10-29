<h1 align="center"><a href="README.fa.md"><kbd>فارسی</kbd></a></h1>

# PasarGuard Light Backup

Adds **option 7** to `pasarguard backup-service`: backups skip the rows in
`node_user_usages` and `node_usages` but keep their table schemas, so backups
stay small and restores still work.

Works with every database supported by the PasarGuard backup script:

| Database | How light mode works |
|---|---|
| MySQL / MariaDB | `--ignore-table` for the two usage tables, then appends their `CREATE TABLE` schema |
| PostgreSQL / TimescaleDB | `pg_dump --exclude-table-data` for the two usage tables |
| SQLite | copies the DB, deletes the two tables' rows on the copy, then `VACUUM` |

## Install

Run as root on the PasarGuard panel server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Aknuun/pasarguard-light-backup/main/install.sh)
```

Requires the backup service to be configured (`BACKUP_SERVICE_ENABLED=true`).
The installer is idempotent, backs up the files it changes, and does not restart
the panel.

## Use

```bash
pasarguard backup-service
```

Option **7** toggles light backup and is enabled by the installer. The cron job
`pasarguard backup` uses it immediately.

## Notes

- Restore into a **fresh or dropped database**. Restoring over an existing
  database keeps the old usage rows, because the dump excludes them.
- Usage history in those two tables is **not** backed up.
- SQLite backups need temporary disk space about the size of the database while
  `VACUUM` runs; the backup takes longer than a plain copy.
- Make a full backup first if you need a rollback.
- The custom `/usr/local/bin/lib` directory shadows PasarGuard script updates.
  After updating PasarGuard, remove it and re-run the installer.
- Tested on PasarGuard 5.5.1: MySQL 9.7.4 and SQLite (2.28 GB database).
  PostgreSQL/TimescaleDB paths use `pg_dump --exclude-table-data`.

## Uninstall

```bash
rm -rf /usr/local/bin/lib
rm -f /etc/pasarguard/backup-light
```

If `/usr/local/bin/lib` existed before installation, restore it from
`/root/pasarguard-light-backup-<timestamp>/custom-lib-before.tar.gz`.

## Upstream

Feature request: https://github.com/PasarGuard/scripts/issues/43
