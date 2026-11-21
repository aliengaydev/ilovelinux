#!/usr/bin/env bash
# Розділ 1: статична адреса на host-only інтерфейсі, hostname.
# Через NetworkManager (Pop!_OS керує мережею саме ним), тож конфіг переживає reboot.
source "$(dirname "$0")/lib.sh"; need_root

CON=lab-hostonly
cur=$(nmcli -g GENERAL.CONNECTION device show "$LAB_IFACE" || true)
if [[ -n "$cur" && "$cur" != "$CON" ]]; then
  log "перейменовую профіль '$cur' -> $CON"
  nmcli connection modify "$cur" connection.id "$CON"
elif ! nmcli -g connection.id connection show "$CON" &>/dev/null; then
  nmcli connection add type ethernet ifname "$LAB_IFACE" con-name "$CON"
fi

log "$CON: $SERVER_IP/24, без default route, DNS $SERVER_IP для ~$LAB_DOMAIN"
nmcli connection modify "$CON" \
  connection.interface-name "$LAB_IFACE" connection.autoconnect yes \
  ipv4.method manual ipv4.addresses "$SERVER_IP/24" ipv4.gateway "" \
  ipv4.never-default yes ipv4.dns "$SERVER_IP" ipv4.dns-search "~$LAB_DOMAIN" \
  ipv6.method link-local
nmcli connection up "$CON" >/dev/null

log "hostname -> $SERVER_HOST"
hostnamectl set-hostname "$SERVER_HOST"
sed -i "/[[:space:]]$SERVER_HOST\([[:space:]]\|$\)/d" /etc/hosts
echo "$SERVER_IP	$SERVER_HOST.$LAB_DOMAIN $SERVER_HOST" >> /etc/hosts

ip -br addr show "$LAB_IFACE"; hostnamectl --static
ok "мережа налаштована"
