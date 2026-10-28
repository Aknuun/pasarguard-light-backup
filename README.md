# PasarGuard Light Backup

Adds **option 7** to `pasarguard backup-service` and turns it on automatically.

Light mode backs up everything **except the rows** of `node_user_usages` and
`node_usages`. It still writes their `CREATE TABLE` schema, so the panel and the
usage jobs work after a restore. This makes backups much smaller on large panels.

## Install

Run as root on the PasarGuard panel server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Aknuun/pasarguard-light-backup/main/install.sh)
```

The backup service must already be configured (`BACKUP_SERVICE_ENABLED=true`),
because option 7 lives inside the `pasarguard backup-service` menu.

## Use

```bash
pasarguard backup-service
```

You will see:

```text
Light backup: ON
...
6. Exit
7. Toggle light backup [ON]
```

Option 7 switches between light and full backup. The installer enables light mode
for you, so the cron job (`pasarguard backup`) uses it immediately.

Manual test:

```bash
pasarguard backup
```

Then inspect the new archive under `/opt/pasarguard/backup/`. In `db_backup.sql`:

- `INSERT INTO node_user_usages` / `node_usages` → **0**
- `CREATE TABLE IF NOT EXISTS node_user_usages` / `node_usages` → **1 each**
- the dump still has its header and `-- Dump completed on ...` line

## What the installer changes

- Copies the official scripts from `/usr/local/lib/pasarguard-scripts/lib` to
  `/usr/local/bin/lib`. The wrapper uses this directory and skips its GitHub
  refresh, so the patch survives normal runs.
- Patches `/usr/local/bin/lib/pasarguard-backup.sh`:
  - light-mode helpers (`is_light_backup`, `toggle_light_backup`,
    `append_light_schema`);
  - `--ignore-table=...node_user_usages` and `...node_usages` on every
    MySQL/MariaDB dump branch;
  - schema-only dump of those two tables, appended to `db_backup.sql`;
  - menu option 7 and the `Light backup: ON/OFF` status line.
- Creates `/etc/pasarguard/backup-light` (the switch).
- Backs up the original libs and the previous custom libs under
  `/root/pasarguard-light-backup-<timestamp>/`.
- Does **not** restart the panel or change the database.

No panel restart is needed.

## Important

- **Usage history is not backed up.** The rows in `node_user_usages` and
  `node_usages` are intentionally skipped; their tables and schema remain.
- **Restore into an empty database.** The dump excludes those rows, and the
  restore does not truncate existing tables. Restoring over a live database
  leaves the old usage rows in place. Drop/recreate the database first, or
  restore only to a fresh one.
- **Make a full backup before the first light backup** if you need a rollback.
- The custom `/usr/local/bin/lib` directory **shadows future PasarGuard script
  updates**. After updating PasarGuard, remove `/usr/local/bin/lib`, then run the
  installer again (or apply the same patch to the new lib). Until then the old
  scripts remain in use.
- Requires `bash`, `python3`, and Docker (standard PasarGuard panel).
- Tested with PasarGuard 5.5.1 and its Docker MySQL container (MySQL 9.7.4).
  The schema dump uses `mariadb-dump` when present, otherwise `mysqldump`.
  Works with the standard `/usr/local/bin/pasarguard` layout.

## Uninstall

```bash
rm -rf /usr/local/bin/lib
rm -f /etc/pasarguard/backup-light
```

If `/usr/local/bin/lib` existed before installation, restore it from
`/root/pasarguard-light-backup-<timestamp>/custom-lib-before.tar.gz` instead of
deleting it.

## خلاصه فارسی

این نصاب گزینه **۷** را به `pasarguard backup-service` اضافه می‌کند و همان اول
حالت سبک را فعال می‌کند. در بکاپ سبک، ردیف‌های `node_user_usages` و
`node_usages` ذخیره نمی‌شوند ولی ساختار (CREATE TABLE) آن‌ها داخل بکاپ می‌ماند.
ریستور باید روی دیتابیس خالی انجام شود؛ روی دیتابیس موجود، ردیف‌های قدیمی باقی
می‌مانند. تاریخچهٔ usage در این دو جدول بکاپ نمی‌شود.
