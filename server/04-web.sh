#!/usr/bin/env bash
# Розділ 4 + 6: nginx — сторінка студента та reverse proxy для застосунку.
source "$(dirname "$0")/lib.sh"; need_root

install -d -m 755 /var/www/lab-server
install_cfg www/index.html /var/www/lab-server/index.html
install_cfg www/50x.html   /var/www/lab-server/50x.html
install_cfg nginx/lab-hardening.conf /etc/nginx/conf.d/lab-hardening.conf
install_cfg nginx/lab-server.conf    /etc/nginx/sites-available/lab-server.conf
install_cfg nginx/app.conf           /etc/nginx/sites-available/app.conf
ln -sfn ../sites-available/lab-server.conf /etc/nginx/sites-enabled/lab-server.conf
ln -sfn ../sites-available/app.conf        /etc/nginx/sites-enabled/app.conf
# Дефолтний сайт пакета теж має default_server — відключаємо (файл у sites-available лишається)
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx >/dev/null 2>&1
systemctl reload-or-restart nginx
ok "nginx: $(systemctl is-active nginx), enabled: $(systemctl is-enabled nginx)"
