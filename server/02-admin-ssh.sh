#!/usr/bin/env bash
# Розділ 2: адміністративний обліковий запис + SSH лише за ключами.
source "$(dirname "$0")/lib.sh"; need_root

getent group sshusers >/dev/null || groupadd --system sshusers

if ! id "$ADMIN_USER" &>/dev/null; then
  log "створюю $ADMIN_USER"
  useradd -m -s /bin/bash -c "Lab administrator" "$ADMIN_USER"
fi
usermod -aG sudo,sshusers,adm "$ADMIN_USER"
set_initial_password "$ADMIN_USER"   # пароль потрібен лише для sudo, не для входу

# Публічні ключі з репозиторію (server/keys/<user>.pub)
install_keys() {
  local u=$1 f="$SRV/keys/$1.pub" h
  [[ -f $f ]] || { echo "  (немає $f — пропускаю ключ для $u)"; return 0; }
  h=$(getent passwd "$u" | cut -d: -f6)
  install -d -m 700 -o "$u" -g "$u" "$h/.ssh"
  install -m 600 -o "$u" -g "$u" "$f" "$h/.ssh/authorized_keys"
  ok "ключ для $u встановлено"
}
install_keys "$ADMIN_USER"

[[ -s "$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.ssh/authorized_keys" ]] \
  || die "у $ADMIN_USER немає authorized_keys — не вимикаю парольний вхід, щоб не втратити доступ"

install_cfg ssh/10-lab.conf /etc/ssh/sshd_config.d/10-lab.conf
sshd -t || die "sshd -t: помилка конфігурації"
systemctl enable --now ssh.socket 2>/dev/null || systemctl enable --now ssh.service
systemctl restart ssh.service 2>/dev/null || true

log "root: блокую пароль (вхід лише через sudo)"
passwd -l root >/dev/null

sshd -T 2>/dev/null | grep -Ei '^(permitrootlogin|passwordauthentication|allowgroups|authenticationmethods) '
ok "SSH захищено"
