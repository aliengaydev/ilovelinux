#!/usr/bin/env bash
# Розділ 5: Gitea + PostgreSQL у контейнерах, керуються systemd-юнітом lab-app.service.
source "$(dirname "$0")/lib.sh"; need_root

install -d -m 750 "$APP_DIR"
install_cfg app/docker-compose.yml "$APP_DIR/docker-compose.yml" 0640
if [[ ! -f "$APP_DIR/.env" ]]; then
  log "генерую $APP_DIR/.env"
  install -m 600 /dev/null "$APP_DIR/.env"
  printf 'POSTGRES_DB=gitea\nPOSTGRES_USER=gitea\nPOSTGRES_PASSWORD=%s\n' "$(gen_pass)" > "$APP_DIR/.env"
fi

install_cfg systemd/lab-app.service /etc/systemd/system/lab-app.service
systemctl daemon-reload
systemctl enable docker.service >/dev/null 2>&1
systemctl enable lab-app.service >/dev/null 2>&1
log "docker compose up (може тривати — завантаження образів)"
systemctl restart lab-app.service

cd "$APP_DIR"
docker compose ps
# Обліковий запис адміністратора Gitea (одноразово)
if ! docker compose exec -T -u git gitea gitea admin user list 2>/dev/null | awk 'NR>1{print $2}' | grep -qx gitadmin; then
  p=$(gen_pass)
  docker compose exec -T -u git gitea gitea admin user create --admin \
    --username gitadmin --password "$p" --email gitadmin@student.lab --must-change-password=false
  echo "gitea/gitadmin:$p" >> "$PASSFILE"; chmod 600 "$PASSFILE"
fi
curl -fsS http://127.0.0.1:3000/api/healthz | head -c 300; echo
ok "застосунок запущено"
