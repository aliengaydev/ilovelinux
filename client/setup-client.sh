#!/usr/bin/env bash
# Налаштування робочої станції lab-client. Запуск на клієнті: sudo bash setup-client.sh
# УВАГА: зміна IP розриває поточну SSH-сесію — запускати через nohup (див. README).
set -euo pipefail
CLIENT_IP=192.168.56.20
SERVER_IP=192.168.56.10
DOMAIN=student.lab
HOST=lab-client
CON=lab-hostonly
[[ $EUID -eq 0 ]] || { echo "sudo!"; exit 1; }

echo "==> інструменти для перевірки сервісів"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq nmap dnsutils curl openssh-client >/dev/null

echo "==> hostname $HOST"
hostnamectl set-hostname "$HOST"
sed -i "/[[:space:]]$HOST\([[:space:]]\|$\)/d" /etc/hosts
echo "$CLIENT_IP	$HOST.$DOMAIN $HOST" >> /etc/hosts

# host-only інтерфейс = той, що має адресу в 192.168.56.0/24 (або вже має профіль lab-hostonly)
IFACE=$(nmcli -g connection.interface-name connection show "$CON" 2>/dev/null || true)
[[ -n $IFACE ]] || IFACE=$(ip -o -4 addr show | awk '$4 ~ /^192\.168\.56\./ {print $2; exit}')
[[ -n $IFACE ]] || { echo "не знайдено інтерфейс у 192.168.56.0/24"; exit 1; }
cur=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" || true)
[[ -n $cur && $cur != "$CON" ]] && nmcli connection modify "$cur" connection.id "$CON"

echo "==> $IFACE: $CLIENT_IP/24, DNS $SERVER_IP лише для ~$DOMAIN"
nmcli connection modify "$CON" connection.interface-name "$IFACE" connection.autoconnect yes \
  ipv4.method manual ipv4.addresses "$CLIENT_IP/24" ipv4.gateway "" ipv4.never-default yes \
  ipv4.dns "$SERVER_IP" ipv4.dns-search "~$DOMAIN" ipv6.method link-local
nmcli connection up "$CON"
ip -br addr show "$IFACE"
echo "OK: клієнт налаштовано"
