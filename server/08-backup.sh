#!/usr/bin/env bash
# Розділ 8: резервне копіювання за розкладом + інструмент відновлення.
source "$(dirname "$0")/lib.sh"; need_root

install -m 0750 -o root -g root "$SRV/backup/lab-backup"  /usr/local/sbin/lab-backup
install -m 0750 -o root -g root "$SRV/backup/lab-restore" /usr/local/sbin/lab-restore
install_cfg systemd/lab-backup.service /etc/systemd/system/lab-backup.service
install_cfg systemd/lab-backup.timer   /etc/systemd/system/lab-backup.timer
install -d -m 700 -o root -g root "$BACKUP_DIR"
systemctl daemon-reload
systemctl enable --now lab-backup.timer >/dev/null 2>&1

log "перша копія"
systemctl start lab-backup.service
journalctl -u lab-backup.service -n 20 --no-pager -o cat | grep lab-backup
systemctl list-timers lab-backup.timer --no-pager | head -2
ok "backup налаштовано"
