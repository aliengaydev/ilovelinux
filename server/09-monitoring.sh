#!/usr/bin/env bash
# Розділ 9: власний healthcheck + запуск за таймером + MOTD.
source "$(dirname "$0")/lib.sh"; need_root

install -m 0755 -o root -g root "$SRV/monitoring/healthcheck" /usr/local/bin/healthcheck
install -m 0755 -o root -g root "$SRV/monitoring/99-lab-health" /etc/update-motd.d/99-lab-health
install_cfg systemd/healthcheck.service /etc/systemd/system/healthcheck.service
install_cfg systemd/healthcheck.timer   /etc/systemd/system/healthcheck.timer
systemctl daemon-reload
systemctl enable --now healthcheck.timer >/dev/null 2>&1
systemctl start healthcheck.service
systemctl list-timers healthcheck.timer --no-pager | head -2
ok "моніторинг налаштовано — запуск: sudo healthcheck"
