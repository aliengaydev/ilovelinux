#!/usr/bin/env bash
# tests/verify.sh — наскрізна перевірка інфраструктури З КЛІЄНТА (lab-client).
# Запуск на клієнті:  bash verify.sh      (потрібні ключі ~/.ssh/lab_* і аліаси з client/ssh_config)
# Код виходу: 0 — все пройшло, 1 — є провали.
set -uo pipefail
SERVER=lab-server.student.lab; SERVER_IP=192.168.56.10
PASS=0; FAIL=0
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else G= R= B= N=; fi
check() {   # check "опис" команда...
  local d=$1; shift
  if out=$("$@" 2>&1); then PASS=$((PASS+1)); printf '  %s[PASS]%s %s\n' "$G" "$N" "$d"
  else FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n         %s\n' "$R" "$N" "$d" "$(head -2 <<<"$out" | tr '\n' ' ')"; fi
}
section() { printf '%s%s%s\n' "$B" "$1" "$N"; }
# Одне SSH-зʼєднання на користувача (ControlMaster): ufw `limit` на 22/tcp відхиляє джерело,
# що відкрило >= 6 нових зʼєднань за 30 с, тож тест не повинен «штурмувати» порт.
CM="$HOME/.ssh/verify-cm-%r@%h:%p"
SSHO=(-o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=auto -o "ControlPath=$CM" -o ControlPersist=60)
NOCM=(-o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=no -o ControlPath=none)
denied() {  # denied <команда...>: успіх лише якщо команда впала саме з "Permission denied" (а не через мережу)
  local o; o=$("$@" 2>&1) && { echo "дозволено (а не мало б): $o"; return 1; }
  grep -q "Permission denied" <<<"$o" || { echo "інша помилка: $o"; return 1; }
}

echo "${B}verify.sh — $(hostname) → $SERVER — $(date '+%F %T')${N}"

section "1. Мережа"
check "клієнт має 192.168.56.20 і hostname lab-client" bash -c 'ip -4 -br a | grep -q "192.168.56.20/24" && [[ $(hostname) == lab-client ]]'
check "сервер відповідає на ping" ping -c1 -W2 "$SERVER_IP"

section "2. DNS (dnsmasq на сервері)"
for h in lab-server www app; do
  check "$h.student.lab -> $SERVER_IP" bash -c "[[ \$(dig +short +time=2 $h.student.lab | tail -1) == $SERVER_IP ]]"
done
check "lab-client.student.lab -> 192.168.56.20" bash -c '[[ $(dig +short lab-client.student.lab) == 192.168.56.20 ]]'
check "інтернет-DNS через NAT не зламано" bash -c 'dig +short +time=3 example.com | grep -qE "^[0-9.]+$"'

section "3. Web-сервіс"
page=$(curl -s -m5 http://www.student.lab/ || true)
check "www: HTTP 200" bash -c '[[ $(curl -s -m5 -o /dev/null -w "%{http_code}" http://www.student.lab/) == 200 ]]'
check "сторінка: Oleksandr Cherniavskyi" grep -q "Oleksandr Cherniavskyi" <<<"$page"
check "сторінка: KH-24" grep -q "KH-24" <<<"$page"
check "сторінка: hostname lab-server (SSI)" grep -q "<code>lab-server</code>" <<<"$page"

section "4. Застосунок через reverse proxy"
check "app.student.lab: HTTP 200" bash -c '[[ $(curl -s -m5 -o /dev/null -w "%{http_code}" http://app.student.lab/) == 200 ]]'
check "Gitea healthz: pass (у т.ч. БД)" bash -c 'curl -s -m5 http://app.student.lab/api/healthz | grep -q "\"status\": \"pass\""'
check "дані збереглись: repo gitadmin/demo-project" bash -c '[[ $(curl -s -m5 -o /dev/null -w "%{http_code}" http://app.student.lab/api/v1/repos/gitadmin/demo-project) == 200 ]]'

section "5. Мережева безпека (ззовні)"
for p in 22 53 80; do check "порт $p відкритий" timeout 3 bash -c "echo > /dev/tcp/$SERVER_IP/$p"; done
for p in 3000 5432 8080 443; do check "порт $p закритий" bash -c "! timeout 3 bash -c 'echo > /dev/tcp/$SERVER_IP/$p' 2>/dev/null"; done

section "6. SSH"
echo "  (пауза 30 с — скидаю вікно ufw limit після перевірки порту 22)"; sleep 30
check "sysadmin: вхід за ключем" ssh "${SSHO[@]}" lab-admin true
check "sysadmin: вхід паролем заборонено" denied ssh "${NOCM[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password sysadmin@"$SERVER" true
check "root: вхід заборонено (навіть з валідним ключем)" denied ssh "${NOCM[@]}" -i ~/.ssh/lab_sysadmin -o IdentitiesOnly=yes root@"$SERVER" true
check "sysadmin має sudo" bash -c 'ssh '"${SSHO[*]}"' lab-admin "id -nG" | grep -qw sudo'

section "7. Спільна робота розробників"
f=/srv/projects/devteam/.verify-$$
check "dev1 створює файл (umask 077) -> група devteam, rw для групи" \
  ssh "${SSHO[@]}" lab-dev1 "umask 077; echo dev1 > $f && stat -c '%A %G' $f | grep -q '^-rw-rw----+\? devteam'"
check "dev2 редагує файл dev1" ssh "${SSHO[@]}" lab-dev2 "echo dev2 >> $f && grep -q dev2 $f"
check "dev2 не читає приватний home dev1" denied ssh "${SSHO[@]}" lab-dev2 'ls /home/dev1'
ssh "${SSHO[@]}" lab-dev2 "rm -f $f" 2>/dev/null

section "8. Стан сервера (останній healthcheck, без sudo)"
hc=$(ssh "${SSHO[@]}" lab-admin 'cat /var/lib/healthcheck/last.txt; echo; echo "age_min=$(( ($(date +%s) - $(stat -c %Y /var/lib/healthcheck/last.txt)) / 60 ))"' 2>/dev/null || true)
check "healthcheck: OK — система в нормі" grep -q "СТАН: OK" <<<"$hc"
age=$(sed -n 's/^age_min=//p' <<<"$hc"); age=${age:-999}
check "healthcheck свіжий (< 10 хв, зараз ${age} хв)" test "$age" -lt 10
grep -E '\[(WARN|CRIT)\]' <<<"$hc" | sed 's/^/        /'
ssh "${SSHO[@]}" lab-admin 'echo "        uptime: $(uptime -p), boot: $(uptime -s)"' 2>/dev/null

for h in lab-admin lab-dev1 lab-dev2; do ssh -O exit -o "ControlPath=$CM" "$h" 2>/dev/null; done

section "9. Захист від перебору (ufw limit на 22/tcp)"
echo "  (пауза 30 с, потім 8 швидких нових зʼєднань)"; sleep 30
refused=0; for i in $(seq 1 8); do timeout 3 bash -c "echo > /dev/tcp/$SERVER_IP/22" 2>/dev/null || refused=$((refused+1)); done
check "після 6 зʼєднань за 30 с нові відхиляються (відхилено $refused з 8)" test "$refused" -ge 1
echo "  (після цього тесту SSH з цього клієнта ~30 с недоступний — так і задумано)"

echo
if (( FAIL == 0 )); then echo "${G}${B}РЕЗУЛЬТАТ: усі $PASS перевірок пройдено${N}"; exit 0
else echo "${R}${B}РЕЗУЛЬТАТ: провалено $FAIL з $((PASS+FAIL))${N}"; exit 1; fi
