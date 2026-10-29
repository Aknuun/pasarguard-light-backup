#!/usr/bin/env bash
# PasarGuard light backup installer
# Adds "7. Toggle light backup" to `pasarguard backup-service` and enables it.
# Light mode excludes node_user_usages and node_usages rows but keeps their schema.
set -euo pipefail

BIN="${PASARGUARD_BIN:-/usr/local/bin/pasarguard}"
SRC_LIB="${PASARGUARD_SRC_LIB:-/usr/local/lib/pasarguard-scripts/lib}"
DST_LIB="${PASARGUARD_DST_LIB:-/usr/local/bin/lib}"
FLAG="${PASARGUARD_LIGHT_FLAG:-/etc/pasarguard/backup-light}"
LIB_NAME="pasarguard-backup.sh"

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$BIN" ] || die "PasarGuard wrapper not found: $BIN"
[ -f "$SRC_LIB/$LIB_NAME" ] || die "PasarGuard backup lib not found: $SRC_LIB/$LIB_NAME"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# Back up the official libs and any existing custom backup lib.
TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/pasarguard-light-backup-$TS"
mkdir -p "$BK"
tar -C "$(dirname "$SRC_LIB")" -czf "$BK/official-lib.tar.gz" "$(basename "$SRC_LIB")" 2>/dev/null || true
if [ -d "$DST_LIB" ]; then
    tar -C "$(dirname "$DST_LIB")" -czf "$BK/custom-lib-before.tar.gz" "$(basename "$DST_LIB")" 2>/dev/null || true
fi

# The wrapper uses /usr/local/bin/lib when it exists and skips the GitHub refresh.
if [ ! -f "$DST_LIB/common.sh" ]; then
    mkdir -p "$DST_LIB"
    for f in "$SRC_LIB"/*; do
        b="$(basename "$f")"
        # Never overwrite an already patched backup lib.
        [ "$b" = "$LIB_NAME" ] && [ -f "$DST_LIB/$b" ] && continue
        cp -a "$f" "$DST_LIB/$b"
    done
fi
[ -f "$DST_LIB/$LIB_NAME" ] || cp -a "$SRC_LIB/$LIB_NAME" "$DST_LIB/$LIB_NAME"
cp -a "$DST_LIB/$LIB_NAME" "$BK/pasarguard-backup.sh.before"

# Patch the custom lib. Idempotent: already-patched sections are left alone.
python3 - "$DST_LIB/$LIB_NAME" <<'PY'
import os
import re
import subprocess
import sys

path = sys.argv[1]
s = open(path, "r", encoding="utf-8").read()
orig = s
changed = []

HELPERS = r'''
# --- light backup helpers ---
LIGHT_BACKUP_FILE="/etc/pasarguard/backup-light"

is_light_backup() {
    [ -f "$LIGHT_BACKUP_FILE" ] || [ "${PASARGUARD_BACKUP_LIGHT:-0}" = "1" ]
}

toggle_light_backup() {
    if [ -f "$LIGHT_BACKUP_FILE" ]; then
        rm -f "$LIGHT_BACKUP_FILE"
        colorized_echo yellow "Light backup disabled (full backup mode)."
    else
        mkdir -p "$(dirname "$LIGHT_BACKUP_FILE")"
        touch "$LIGHT_BACKUP_FILE"
        colorized_echo green "Light backup enabled: node_user_usages and node_usages will be skipped."
    fi
}

append_light_schema() {
    local container="$1"
    local db="$2"
    [ -n "$container" ] && [ -n "$db" ] || return 0
    [ -s "$temp_dir/db_backup.sql" ] || return 0

    local db_user="root"
    local db_pass="${MYSQL_ROOT_PASSWORD:-}"
    if [ -z "$db_pass" ]; then
        db_user="${DB_USER:-${MYSQL_USER:-root}}"
        db_pass="${DB_PASSWORD:-${MYSQL_PASSWORD:-}}"
    fi
    [ -n "$db_pass" ] || return 0

    local dump_cmd="mariadb-dump"
    if ! docker exec "$container" mariadb-dump --version >/dev/null 2>&1; then
        dump_cmd="mysqldump"
    fi

    local schema_file
    schema_file=$(mktemp) || return 0
    if ! docker exec -e MYSQL_PWD="$db_pass" "$container" "$dump_cmd" \
        -u "$db_user" --no-data --skip-add-drop-table --skip-comments --compact --no-create-db \
        "$db" node_user_usages node_usages >"$schema_file" 2>>"$log_file"; then
        rm -f "$schema_file"
        return 0
    fi

    sed -i '/^-- Dump completed on/d' "$temp_dir/db_backup.sql"
    {
        printf '\n-- Light backup: schema for excluded usage tables\n'
        printf 'USE `%s`;\n' "$db"
        sed 's/^CREATE TABLE /CREATE TABLE IF NOT EXISTS /' "$schema_file"
        printf -- '-- Dump completed on %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    } >>"$temp_dir/db_backup.sql"
    rm -f "$schema_file"
}

sqlite_light_prune() {
    local snapshot="$1"
    is_light_backup || return 0
    [ -f "$snapshot" ] || return 1
    command -v sqlite3 >/dev/null 2>&1 || return 1
    if ! sqlite3 "$snapshot" \
        "PRAGMA journal_mode=DELETE; DELETE FROM node_user_usages; DELETE FROM node_usages; VACUUM;" \
        >>"$log_file" 2>&1; then
        return 1
    fi
    rm -f "${snapshot}-wal" "${snapshot}-shm" "${snapshot}-journal" 2>/dev/null || true
    return 0
}
'''

SQLITE_HELPER = r'''
sqlite_light_prune() {
    local snapshot="$1"
    is_light_backup || return 0
    [ -f "$snapshot" ] || return 1
    command -v sqlite3 >/dev/null 2>&1 || return 1
    if ! sqlite3 "$snapshot" \
        "PRAGMA journal_mode=DELETE; DELETE FROM node_user_usages; DELETE FROM node_usages; VACUUM;" \
        >>"$log_file" 2>&1; then
        return 1
    fi
    rm -f "${snapshot}-wal" "${snapshot}-shm" "${snapshot}-journal" 2>/dev/null || true
    return 0
}
'''

if "LIGHT_BACKUP_FILE=" not in s:
    if "backup_service() {" not in s:
        sys.exit("backup_service() not found; unsupported PasarGuard backup lib")
    s = s.replace("backup_service() {", HELPERS + "\nbackup_service() {", 1)
    changed.append("helpers")
elif "append_light_schema()" not in s:
    sys.exit("partial light backup patch detected (helpers exist, append_light_schema missing)")

if "sqlite_light_prune()" not in s:
    if "backup_service() {" not in s:
        sys.exit("backup_service() not found; unsupported PasarGuard backup lib")
    s = s.replace("backup_service() {", SQLITE_HELPER + "\nbackup_service() {", 1)
    changed.append("sqlite helper")

if 'local light_status="OFF"' not in s:
    if '    local backup_proxy_url=""\n' in s:
        s = s.replace('    local backup_proxy_url=""\n',
                      '    local backup_proxy_url=""\n    local light_status="OFF"\n', 1)
    else:
        s = s.replace('backup_service() {\n',
                      'backup_service() {\n    local light_status="OFF"\n', 1)
    changed.append("light_status local")

if 'light_status="ON"' not in s:
    needle = '            masked_telegram_bot_key=$(mask_telegram_bot_key "$telegram_bot_key")\n'
    if needle not in s:
        sys.exit("mask_telegram_bot_key block not found; unsupported menu layout")
    s = s.replace(needle, needle +
                  '            light_status="OFF"\n'
                  '            [ -f "$LIGHT_BACKUP_FILE" ] && light_status="ON"\n', 1)
    changed.append("light_status refresh")

if 'Light backup: $light_status' not in s:
    needle = '            echo "Choose an option:"\n'
    if needle not in s:
        sys.exit('menu "Choose an option:" not found')
    s = s.replace(needle,
                  '            colorized_echo cyan "Light backup: $light_status"\n' + needle, 1)
    changed.append("status line")

if 'Toggle light backup' not in s:
    s, n = re.subn(
        r'echo "6\. Exit"\n(\s*)read -p "Enter your choice \(1-6\): " user_choice',
        'echo "6. Exit"\n\\1echo "7. Toggle light backup [$light_status]"\n'
        '\\1read -p "Enter your choice (1-7): " user_choice',
        s, count=1)
    if not n:
        sys.exit("backup-service 1-6 menu not found; unsupported menu layout")
    changed.append("menu option 7")

if not re.search(r'\n\s*7\)\s*\n\s*toggle_light_backup', s):
    idx = s.find('read -p "Enter your choice (1-7)')
    if idx < 0:
        idx = s.find('read -p "Enter your choice (1-6)')
    if idx < 0:
        sys.exit("menu prompt not found")
    m = re.search(r'(?m)^(\s*)\*\)\s*$', s[idx:])
    if not m:
        sys.exit("menu default case not found")
    pos = idx + m.start()
    indent = m.group(1)
    s = s[:pos] + (f'{indent}7)\n'
                        f'{indent}    toggle_light_backup\n'
                        f'{indent}    echo ""\n'
                        f'{indent}    ;;\n') + s[pos:]
    changed.append("case 7")

if "LIGHT_IGNORE_ARGS" not in s:
    needle = '        colorized_echo blue "Backing up database..."\n'
    if needle not in s:
        sys.exit("database backup marker not found")
    s = s.replace(needle, needle +
                  '        local -a LIGHT_IGNORE_ARGS=()\n'
                  '        if is_light_backup && [ -n "${db_name:-}" ]; then\n'
                  '            LIGHT_IGNORE_ARGS=(--ignore-table="${db_name}.node_user_usages" --ignore-table="${db_name}.node_usages")\n'
                  '        fi\n', 1)
    changed.append("ignore args")

if "LIGHT_PG_ARGS" not in s:
    needle = '        local -a LIGHT_IGNORE_ARGS=()\n'
    if needle not in s:
        sys.exit("light ignore-args block not found")
    s = s.replace(needle, needle +
                  '        local -a LIGHT_PG_ARGS=()\n'
                  '        if is_light_backup; then\n'
                  "            LIGHT_PG_ARGS=(--exclude-table-data='*.node_user_usages' --exclude-table-data='*.node_usages')\n"
                  '        fi\n', 1)
    changed.append("postgres args")

if 'sqlite_light_prune "$sqlite_snapshot_dir/$sqlite_basename"' not in s:
    needle = ('                    elif ! sqlite3 "$sqlite_file" ".backup \'$sqlite_snapshot_dir/$sqlite_basename\'" >>"$log_file" 2>&1; then\n'
              '                        error_messages+=("Failed to create SQLite backup snapshot.")\n'
              '                    fi\n')
    if needle not in s:
        sys.exit("SQLite snapshot marker not found")
    s = s.replace(needle,
                  '                    elif ! sqlite3 "$sqlite_file" ".backup \'$sqlite_snapshot_dir/$sqlite_basename\'" >>"$log_file" 2>&1; then\n'
                  '                        error_messages+=("Failed to create SQLite backup snapshot.")\n'
                  '                    elif is_light_backup && ! sqlite_light_prune "$sqlite_snapshot_dir/$sqlite_basename"; then\n'
                  '                        error_messages+=("Failed to prune usage tables from SQLite snapshot.")\n'
                  '                    fi\n', 1)
    changed.append("sqlite prune")

lines = s.splitlines(True)
dump_patched = 0
for i, line in enumerate(lines):
    if ('mariadb-dump' in line or '"$dump_cmd"' in line) and '>"$temp_dir/db_backup.sql"' in line:
        if "LIGHT_IGNORE_ARGS" not in line:
            lines[i] = line.replace('>"$temp_dir/db_backup.sql"',
                                    '"${LIGHT_IGNORE_ARGS[@]}" >"$temp_dir/db_backup.sql"', 1)
            dump_patched += 1
if dump_patched:
    changed.append(f"{dump_patched} dump lines")
s = "".join(lines)

lines = s.splitlines(True)
pg_patched = 0
for i, line in enumerate(lines):
    if 'pg_dump -U' in line and ('>"$out_dir/$filename"' in line or '>"$temp_dir/db_backup.sql"' in line):
        if "LIGHT_PG_ARGS" not in line:
            if '>"$out_dir/$filename"' in line:
                lines[i] = line.replace('>"$out_dir/$filename"',
                                        '"${LIGHT_PG_ARGS[@]}" >"$out_dir/$filename"', 1)
            else:
                lines[i] = line.replace('>"$temp_dir/db_backup.sql"',
                                        '"${LIGHT_PG_ARGS[@]}" >"$temp_dir/db_backup.sql"', 1)
            pg_patched += 1
if pg_patched:
    changed.append(f"{pg_patched} pg_dump lines")
s = "".join(lines)

if 'append_light_schema "${container_name' not in s:
    needle = '        if [ ${#error_messages[@]} -eq 0 ] && ! database_backup_looks_restorable'
    if needle not in s:
        sys.exit("validation marker not found")
    s = s.replace(needle,
                  '        if [ ${#error_messages[@]} -eq 0 ] && is_light_backup '
                  '&& { [ "$db_type" = "mysql" ] || [ "$db_type" = "mariadb" ]; } '
                  '&& [ -s "$temp_dir/db_backup.sql" ]; then\n'
                  '            append_light_schema "${container_name:-}" "$db_name"\n'
                  '        fi\n' + needle, 1)
    changed.append("schema append call")

required = [
    "LIGHT_BACKUP_FILE=",
    "append_light_schema()",
    "sqlite_light_prune()",
    "Toggle light backup",
    'read -p "Enter your choice (1-7)',
    "LIGHT_IGNORE_ARGS",
    "LIGHT_PG_ARGS",
    'append_light_schema "${container_name',
    "Failed to prune usage tables from SQLite snapshot",
]
for marker in required:
    if marker not in s:
        sys.exit(f"patch verification failed: {marker}")
if s.count("LIGHT_IGNORE_ARGS[@]") < 7:
    sys.exit("patch verification failed: fewer than 7 MySQL dump lines patched")
if s.count("LIGHT_PG_ARGS[@]") < 3:
    sys.exit("patch verification failed: fewer than 3 PostgreSQL dump lines patched")

tmp = path + ".new"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(s)
check = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
if check.returncode != 0:
    os.unlink(tmp)
    sys.stderr.write(check.stderr)
    sys.exit(1)
os.replace(tmp, path)

if s == orig:
    print("backup lib already patched")
else:
    print("patched: " + ", ".join(changed))
PY

# Enabled automatically on install.
mkdir -p "$(dirname "$FLAG")"
: > "$FLAG"

echo
echo "Light backup installed and enabled."
echo "Previous files backed up in: $BK"
echo "Run: pasarguard backup-service"
echo "Option 7 should show: Toggle light backup [ON]"
