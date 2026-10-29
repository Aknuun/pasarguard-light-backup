<h2 align="center"><a href="README.md"><kbd>English</kbd></a></h2>

# بکاپ سبک PasarGuard

گزینهٔ **۷** را به `pasarguard backup-service` اضافه می‌کند: بکاپ‌ها ردیف‌های
`node_user_usages` و `node_usages` را رد می‌کنند، ولی ساختار جدول‌ها را حفظ
می‌کنند؛ در نتیجه بکاپ کوچک می‌ماند و ریستور هم کار می‌کند.

با همهٔ دیتابیس‌هایی که اسکریپت بکاپ PasarGuard پشتیبانی می‌کند کار می‌کند:

| دیتابیس | روش بکاپ سبک |
|---|---|
| MySQL / MariaDB | `--ignore-table` برای دو جدول usage و سپس اضافه‌کردن schema آن‌ها |
| PostgreSQL / TimescaleDB | `pg_dump --exclude-table-data` برای دو جدول usage |
| SQLite | کپی دیتابیس، حذف ردیف‌های دو جدول روی کپی، سپس `VACUUM` |

## نصب

روی سرور پنل PasarGuard با کاربر root اجرا کن:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Aknuun/pasarguard-light-backup/main/install.sh)
```

نیازمند تنظیم بودن سرویس بکاپ است (`BACKUP_SERVICE_ENABLED=true`).
نصاب idempotent است، از فایل‌هایی که تغییر می‌دهد بکاپ می‌گیرد و پنل را
ری‌استارت نمی‌کند.

## استفاده

```bash
pasarguard backup-service
```

گزینهٔ **۷** بکاپ سبک را toggle می‌کند و نصاب آن را فعال می‌کند. کران
`pasarguard backup` فوراً از آن استفاده می‌کند.

## نکته‌ها

- ریستور روی دیتابیس **خالی یا DROP‌شده** انجام شود. ریستور روی دیتابیس موجود،
  ردیف‌های قدیمی usage را نگه می‌دارد، چون dump آن‌ها را حذف کرده است.
- تاریخچهٔ usage این دو جدول **بکاپ نمی‌شود**.
- در SQLite هنگام `VACUUM` به فضای موقت تقریباً هم‌اندازهٔ دیتابیس نیاز است و
  بکاپ از یک کپی ساده کندتر می‌شود.
- اگر به rollback نیاز داری، اول یک بکاپ کامل بگیر.
- پوشهٔ سفارشی `/usr/local/bin/lib` روی آپدیت‌های اسکریپت PasarGuard سایه
  می‌اندازد. بعد از آپدیت PasarGuard آن را حذف کن و نصاب را دوباره اجرا کن.
- تست‌شده روی PasarGuard 5.5.1: MySQL 9.7.4 و SQLite (دیتابیس ۲.۲۸ گیگابایتی).
  مسیر PostgreSQL/TimescaleDB از `pg_dump --exclude-table-data` استفاده می‌کند.

## حذف

```bash
rm -rf /usr/local/bin/lib
rm -f /etc/pasarguard/backup-light
```

اگر `/usr/local/bin/lib` قبل از نصب وجود داشت، از
`/root/pasarguard-light-backup-<timestamp>/custom-lib-before.tar.gz` برگردان.

## Upstream

درخواست ویژگی: https://github.com/PasarGuard/scripts/issues/43
