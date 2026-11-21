#!/usr/bin/env bash
# Розділ 0: встановлення пакетів. Ідемпотентний.
source "$(dirname "$0")/lib.sh"; need_root

# Конфіг dnsmasq кладемо ДО встановлення пакета: інакше postinst стартує dnsmasq
# з дефолтним конфігом на всіх інтерфейсах і він конфліктує з systemd-resolved (порт 53).
install_cfg dnsmasq/student.lab.conf /etc/dnsmasq.d/student.lab.conf

log "apt: openssh-server nginx dnsmasq acl curl jq"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openssh-server nginx dnsmasq acl curl jq dnsutils >/dev/null
ok "пакети встановлено"
