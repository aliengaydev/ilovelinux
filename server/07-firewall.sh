#!/usr/bin/env bash
# Розділ 7: ufw — назовні лише SSH, DNS, HTTP і лише з host-only мережі.
# Порт 3000 (Gitea) і 5432 (PostgreSQL) ufw не потрібні: Docker публікує 3000 тільки на
# 127.0.0.1, а 5432 не публікується зовсім (до того ж Docker обходить ufw для опублікованих
# портів — тому захист контейнерів зроблено на рівні bind-адрес, а не правил ufw).
source "$(dirname "$0")/lib.sh"; need_root

ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw default deny routed    >/dev/null   # docker керує FORWARD сам (DOCKER-USER)

ufw limit in on "$LAB_IFACE" from "$LAB_NET" to any port 22 proto tcp comment 'SSH admin/dev (rate-limited)'
ufw allow in on "$LAB_IFACE" from "$LAB_NET" to any port 80 proto tcp comment 'HTTP nginx: www + app'
ufw allow in on "$LAB_IFACE" from "$LAB_NET" to any port 53 proto udp comment 'DNS student.lab'
ufw allow in on "$LAB_IFACE" from "$LAB_NET" to any port 53 proto tcp comment 'DNS student.lab (tcp)'
ufw logging low >/dev/null
ufw --force enable >/dev/null
systemctl enable ufw >/dev/null 2>&1
ufw status verbose
