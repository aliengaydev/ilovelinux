#!/usr/bin/env bash
# Розділ 4/6: доменні імена student.lab через dnsmasq.
source "$(dirname "$0")/lib.sh"; need_root

install_cfg dnsmasq/student.lab.conf /etc/dnsmasq.d/student.lab.conf
# УВАГА: без --conf-dir dnsmasq --test НЕ читає /etc/dnsmasq.d (каталог додає systemd-юніт) і завжди каже OK
dnsmasq --test --conf-dir=/etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new
systemctl enable dnsmasq >/dev/null 2>&1
systemctl restart dnsmasq
# Сам сервер теж питає dnsmasq для ~student.lab (налаштовано у профілі NM в 01-network.sh)
resolvectl flush-caches || true
for h in lab-server www app lab-client; do
  printf '  %-26s -> %s\n' "$h.$LAB_DOMAIN" "$(dig +short @"$SERVER_IP" "$h.$LAB_DOMAIN" A | tail -1)"
done
getent hosts "app.$LAB_DOMAIN" >/dev/null || die "резолвер сервера не бачить app.$LAB_DOMAIN"
ok "DNS працює"
