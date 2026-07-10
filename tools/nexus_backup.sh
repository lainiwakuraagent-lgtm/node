#!/usr/bin/env bash
# nexus_backup.sh — Create a consistent SQLite backup of nexus.db
#
# Uses Python's sqlite3.backup() API (hot backup, safe while server is running).
# Keeps the last 7 daily backups; older ones are pruned automatically.
#
# Usage:
#   bash tools/nexus_backup.sh
#
# Backup location: /home/andrii/lain/nexus/backups/
# Backup filename: nexus_<YYYYMMDD_HHMMSS>.db

set -euo pipefail

DB_SRC="/home/andrii/lain/nexus/nexus.db"
BACKUP_DIR="/home/andrii/lain/nexus/backups"
KEEP=7

if [ ! -f "$DB_SRC" ]; then
    echo "nexus_backup: DB not found at $DB_SRC — skipping"
    exit 0
fi

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
DEST="$BACKUP_DIR/nexus_${TIMESTAMP}.db"

/usr/bin/python3 - "$DB_SRC" "$DEST" << 'PYEOF'
import sqlite3, sys

src_path, dst_path = sys.argv[1], sys.argv[2]

src = sqlite3.connect(src_path)
dst = sqlite3.connect(dst_path)
try:
    src.backup(dst)
    print(f"nexus_backup: backed up to {dst_path}")
finally:
    dst.close()
    src.close()
PYEOF

# Prune old backups — keep only the last $KEEP files
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/nexus_*.db 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$KEEP" ]; then
    EXCESS=$(( BACKUP_COUNT - KEEP ))
    ls -1t "$BACKUP_DIR"/nexus_*.db | tail -"$EXCESS" | xargs rm -f
    echo "nexus_backup: pruned $EXCESS old backup(s), keeping $KEEP"
fi
