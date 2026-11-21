#!/usr/bin/env bash
# Розділ 3: розробники, спільна проєктна зона, приватні дані.
source "$(dirname "$0")/lib.sh"; need_root

# Нові home-каталоги — 0700 (за замовчуванням в Ubuntu 0750, тобто видно групі).
sed -i 's/^#\?HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
grep -q '^HOME_MODE' /etc/login.defs || echo -e 'HOME_MODE\t0700' >> /etc/login.defs

getent group "$PROJECT_GROUP" >/dev/null || groupadd "$PROJECT_GROUP"

for u in $DEV_USERS; do
  id "$u" &>/dev/null || useradd -m -s /bin/bash -c "Developer $u" "$u"
  usermod -aG "$PROJECT_GROUP",sshusers "$u"
  set_initial_password "$u"
done
# Користувач поза командою — для демонстрації відмови в доступі
id "$OUTSIDER_USER" &>/dev/null || useradd -m -s /bin/bash -c "Not in project team" "$OUTSIDER_USER"
set_initial_password "$OUTSIDER_USER"

for u in $ADMIN_USER $DEV_USERS $OUTSIDER_USER; do
  chmod 700 "$(getent passwd "$u" | cut -d: -f6)"
done

# SSH-ключі розробників (server/keys/devN.pub)
for u in $DEV_USERS; do
  f="$SRV/keys/$u.pub"; [[ -f $f ]] || continue
  h=$(getent passwd "$u" | cut -d: -f6)
  install -d -m 700 -o "$u" -g "$u" "$h/.ssh"
  install -m 600 -o "$u" -g "$u" "$f" "$h/.ssh/authorized_keys"
done

log "$PROJECT_ROOT/$PROJECT_GROUP: root:$PROJECT_GROUP 2770 + default ACL"
install -d -m 0755 -o root -g root "$PROJECT_ROOT"
D="$PROJECT_ROOT/$PROJECT_GROUP"
install -d -o root -g "$PROJECT_GROUP" "$D"
chmod 2770 "$D"                       # setgid: нові файли успадковують групу devteam
# Default ACL: нові файли/каталоги отримують g:rw(x) незалежно від umask користувача,
# others — нічого. Застосовуємо й до вже наявного вмісту.
setfacl -R -m  g:"$PROJECT_GROUP":rwX,o::--- "$D"
setfacl -R -d -m u::rwX,g::rwX,g:"$PROJECT_GROUP":rwX,o::--- "$D"
find "$D" -type d -exec chmod g+s {} +

[[ -f "$D/README.txt" ]] || { echo "Спільна зона проєкту команди $PROJECT_GROUP" > "$D/README.txt"; chgrp "$PROJECT_GROUP" "$D/README.txt"; }
getfacl -p "$D"
ok "користувачі та доступи налаштовані"
