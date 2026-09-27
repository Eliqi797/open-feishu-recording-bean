#!/bin/sh
# Run under root after setting BACKUP_ROOT to an independently mounted destination.
# Never delete old backups automatically. Stop the backend for a consistent snapshot.
set -eu
: "${BACKUP_ROOT:?Set BACKUP_ROOT to an independent mounted backup volume}"
mountpoint -q "$BACKUP_ROOT" || { echo 'BACKUP_ROOT must be a mountpoint' >&2; exit 1; }
if [ "$(stat -c %d "$BACKUP_ROOT")" = "$(stat -c %d /var/lib/recordingbean)" ]; then
  echo 'Backup destination shares source filesystem' >&2; exit 1
fi
was_active=0
if systemctl is-active --quiet recordingbean; then was_active=1; fi
restart_service() { if [ "$was_active" = 1 ]; then systemctl start recordingbean; fi; }
trap restart_service EXIT HUP INT TERM
systemctl stop recordingbean
snapshot="$BACKUP_ROOT/recordingbean-$(date -u +%Y%m%dT%H%M%SZ)"
/opt/recordingbean/.venv/bin/python /opt/recordingbean/scripts/backup.py backup /var/lib/recordingbean "$snapshot"
