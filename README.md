# Linux Infrastructure Challenge — student.lab

**Студент:** Oleksandr Cherniavskyi · **Група:** KH-24

Ізольоване Linux-середовище для внутрішньої команди розробки: сервер `lab-server` і робоча станція `lab-client` у приватній мережі 192.168.56.0/24, домен `student.lab`. На сервері працюють корпоративний web-сервіс (nginx) і застосунок команди — Gitea з PostgreSQL у контейнерах. Є розмежування доступу, firewall, автоматичний backup з відновленням, власний healthcheck і runbook для діагностики.

Хід виконання і перевірки кожного кроку — у [PLAN.md](PLAN.md). Умова — [task.txt](task.txt).

## Зміст
1. [Архітектура](#1-архітектура)
2. [Мережа](#2-мережа)
3. [Адміністрування та SSH](#3-адміністрування-та-ssh)
4. [Користувачі та доступ](#4-користувачі-та-доступ)
5. [Web-сервіс](#5-web-сервіс)
6. [Застосунок: Gitea + PostgreSQL](#6-застосунок-gitea--postgresql)
7. [Інтеграція: DNS і reverse proxy](#7-інтеграція-dns-і-reverse-proxy)
8. [Мережева безпека: таблиця портів і доступу](#8-мережева-безпека-таблиця-портів-і-доступу)
9. [Резервне копіювання та відновлення](#9-резервне-копіювання-та-відновлення)
10. [Моніторинг: healthcheck](#10-моніторинг-healthcheck)
11. [Runbook: діагностика несправностей](#11-runbook-діагностика-несправностей)
12. [Reboot-тест](#12-reboot-тест)
13. [Структура репозиторію і розгортання](#13-структура-репозиторію-і-розгортання)
14. [Чекліст демонстрації на захисті](#14-чекліст-демонстрації-на-захисті)

---

## 1. Архітектура

```
                       VirtualBox host
   ┌──────────────────────────────────────────────────────────────────────────┐
   │   NAT (enp0s3, 10.0.2.15) — лише вихід в інтернет (apt, docker pull)     │
   │                                                                          │
   │   ┌──────────────────────┐   host-only 192.168.56.0/24   ┌────────────┐  │
   │   │ lab-client           │ ───────── enp0s8 ──────────── │ lab-server │  │
   │   │ 192.168.56.20        │  ssh:22  dns:53  http:80      │ .10        │  │
   │   │ Pop!_OS 24.04        │                               │ Pop!_OS    │  │
   │   │ браузер, ssh, nmap   │                               │ 24.04      │  │
   │   └──────────────────────┘                               └─────┬──────┘  │
   └────────────────────────────────────────────────────────────────┼─────────┘
                                                                    │
   lab-server всередині:                                            │
   ┌────────────────────────────────────────────────────────────────┴─────────┐
   │ ufw: вхідні лише 22/tcp, 53/udp+tcp, 80/tcp з 192.168.56.0/24 на enp0s8  │
   │                                                                          │
   │ sshd :22 (лише ключі) ─ sysadmin, dev1, dev2                             │
   │ dnsmasq 192.168.56.10:53 ─ зона student.lab                              │
   │ nginx :80 ─┬─ www / lab-server.student.lab → /var/www/lab-server (SSI)   │
   │            └─ app.student.lab ──proxy──► 127.0.0.1:3000                  │
   │                                               │ (docker-proxy, loopback) │
   │   docker: ┌──── lab-frontend ────┐            ▼                          │
   │           │  lab-gitea :3000  ◄──┘──── lab-backend (internal) ───┐       │
   │           │  volume lab_gitea-data      lab-db :5432 (postgres)  │       │
   │           └─────────────────────────── volume lab_pg-data ───────┘       │
   │                                                                          │
   │ /srv/projects/devteam (2770 root:devteam + default ACL)                  │
   │ lab-backup.timer 02:30 → /var/backups/lab   healthcheck.timer кожні 5 хв │
   └──────────────────────────────────────────────────────────────────────────┘
```

| Роль | Host | IP | ОС | Що робить |
|---|---|---|---|---|
| Сервер | `lab-server` | 192.168.56.10 | Pop!_OS 24.04 | SSH, DNS, nginx, Docker (Gitea + PostgreSQL), backup, моніторинг |
| Клієнт | `lab-client` | 192.168.56.20 | Pop!_OS 24.04 | робоча станція: браузер, ssh, перевірка сервісів (curl, dig, nmap) |

**Чому так.** Дві VM у VirtualBox — найпростіший спосіб мати два справжні окремі хости з власними ядрами, мережевими стеками й firewall. Кожна VM має два адаптери: NAT для інтернету (оновлення, образи) і host-only для внутрішньої мережі компанії. Сервіси працюють тільки у внутрішній мережі. Застосунок у контейнерах, бо так вимагає умова, і так його легко пересоздати без втрати даних. Web-сервіс (nginx) — на хості, бо він є «вхідними дверима» для всього і має стартувати незалежно від Docker.

## 2. Мережа

| Параметр | lab-server | lab-client |
|---|---|---|
| enp0s3 (NAT) | DHCP 10.0.2.15, default route | DHCP 10.0.2.15, default route |
| enp0s8 (host-only) | **192.168.56.10/24** статично | **192.168.56.20/24** статично |
| Профіль NetworkManager | `lab-hostonly` | `lab-hostonly` |
| DNS для `student.lab` | 192.168.56.10 (dnsmasq) | 192.168.56.10 |

**Рішення:**
- **NetworkManager, а не netplan/ifupdown.** Pop!_OS керує мережею через NM, тож налаштування через `nmcli` — «рідний» спосіб, який переживає reboot. Профіль перейменовано на `lab-hostonly`, щоб його було видно в `nmcli con`.
- **Статичні адреси поза DHCP-діапазоном VirtualBox** (той роздає з .100). Сервер мусить мати постійну адресу: на неї вказують DNS-записи й правила firewall.
- **`ipv4.never-default yes` на host-only.** Default route лишається через NAT, тож інтернет працює, а внутрішня мережа не перехоплює зовнішній трафік.
- **DNS як routing domain `~student.lab`.** systemd-resolved надсилає на 192.168.56.10 *тільки* запити `*.student.lab`, а решту — звичайним DNS через NAT. Так клієнт бачить внутрішні імена й не втрачає інтернет.

Скрипти: `server/01-network.sh`, `client/setup-client.sh`.

## 3. Адміністрування та SSH

- **Адміністратор `sysadmin`**: окремий обліковий запис у групах `sudo`, `adm`, `sshusers`. Для привілейованих дій використовується `sudo` (з паролем), root напряму не використовується.
- **root**: пароль заблоковано (`passwd -l root`), SSH-вхід заборонено (`PermitRootLogin no`).
- **Автентифікація — лише ключі ed25519.** Пароль адміністратора не передається мережею при кожному підключенні. Ключі генеруються на клієнті (`~/.ssh/lab_sysadmin`, `lab_dev1`, `lab_dev2`), публічні частини лежать у `server/keys/*.pub`.

Конфіг `/etc/ssh/sshd_config.d/10-lab.conf` (`server/ssh/10-lab.conf`):

| Параметр | Значення | Навіщо |
|---|---|---|
| `PasswordAuthentication`, `KbdInteractiveAuthentication` | `no` | немає підбору паролів |
| `AuthenticationMethods` | `publickey` | лише ключ |
| `PermitRootLogin` | `no` | root не входить ніколи |
| `AllowGroups` | `sshusers` | SSH дозволений лише явно визначеним людям (guest і службові акаунти — ні) |
| `MaxAuthTries 3`, `LoginGraceTime 30` | | обмеження спроб |
| `LogLevel VERBOSE` | | у журналі видно відбиток ключа, яким увійшли |

Файл має префікс `10-`, бо sshd бере **перше** знайдене значення параметра, а `sshd_config.d/*.conf` підключається на початку `sshd_config`. Після кожної зміни виконується `sshd -t`. На Pop!_OS 24.04 sshd запускається через socket activation (`ssh.socket`).

На клієнті створено аліаси (`client/ssh_config` → `~/.ssh/config`): `ssh lab-admin`, `ssh lab-dev1`, `ssh lab-dev2`.

**Перевірено з клієнта:** вхід за ключем працює. Вхід паролем, вхід root і вхід користувача поза `sshusers` дають `Permission denied (publickey)`, а в журналі видно `not allowed because none of user's groups are listed in AllowGroups`.

Початкові паролі (потрібні лише для `sudo` і входу в Gitea) згенеровано випадково й збережено **тільки** в `/root/lab-initial-passwords` (0600, не в git).

## 4. Користувачі та доступ

| Обліковий запис | Групи | SSH | sudo | /srv/projects/devteam | Призначення |
|---|---|---|---|---|---|
| `sysadmin` | sudo, adm, sshusers | ключ | так (з паролем) | через sudo | адміністратор |
| `dev1` | devteam, sshusers | ключ | ні | читання/запис | розробник |
| `dev2` | devteam, sshusers | ключ | ні | читання/запис | розробник |
| `guest` | — | ні | ні | **немає доступу** | користувач поза командою (для демонстрації) |
| `root` | | заборонено | | | пароль заблоковано |

**Спільна зона проєкту** — `/srv/projects/devteam`:
- `root:devteam`, режим **2770**: власник root, тож розробник не може «забрати» каталог собі; група devteam має rwx; others не мають нічого.
- **setgid** (2xxx): усі нові файли й підкаталоги автоматично отримують групу `devteam`, а не особисту групу автора.
- **default ACL** `g:devteam:rwX, o::---`: нові файли отримують груповий запис **незалежно від umask** користувача. Навіть з `umask 077` файл буде `rw-rw----`. Лише setgid цього не гарантує: з umask 022 файл був би `rw-r--r--`, і колега не зміг би його редагувати.

**Приватні дані:** домашні каталоги мають режим 0700 (`HOME_MODE 0700` у `/etc/login.defs`, а в Ubuntu за замовчуванням 0750).

**Перевірено:** dev1 по SSH з клієнта створює файл з `umask 077`, він має групу `devteam` і режим `rw-rw----`. dev2 редагує його і пише в каталог dev1. `guest` отримує `Permission denied` і на лістинг, і на читання. dev1 не бачить `/home/dev2`.

Скрипт: `server/03-users.sh`.

## 5. Web-сервіс

- **nginx** з пакета Ubuntu, `systemctl enable nginx` — стартує після reboot.
- Власна конфігурація: `/etc/nginx/sites-available/lab-server.conf` (+ `app.conf`, `conf.d/lab-hardening.conf`), дефолтний сайт вимкнено.
- Сторінка `/var/www/lab-server/index.html` показує **ім'я, групу і hostname сервера**. Hostname підставляє сам nginx через **SSI** (`<!--# echo var="hostname" -->`), тож сторінка завжди показує реальний сервер, на якому відпрацювала, а не зашитий у HTML текст. Також показуються IP сервера, запитаний домен, IP клієнта і час.
- Доступ за іменами `www.student.lab`, `lab-server.student.lab` (і за IP — це `default_server`).
- **Логи** окремо для кожного сайту: `/var/log/nginx/lab-server.{access,error}.log`, `/var/log/nginx/app.{access,error}.log`. Ротацію виконує стандартний `logrotate` пакета nginx (`/var/log/nginx/*.log`).
- `server_tokens off` (версію nginx не видно), `/health` — легкий endpoint для моніторингу.

```
client$ curl http://www.student.lab/     # → Oleksandr Cherniavskyi, KH-24, hostname lab-server
```

## 6. Застосунок: Gitea + PostgreSQL

**Gitea** — self-hosted Git-сервіс (репозиторії, issues, code review), тобто те, чим реально користується команда розробки. Він легкий (~150–200 MB RAM), має офіційний Docker-образ і підтримує PostgreSQL.

`/opt/lab-app/docker-compose.yml` (`server/app/docker-compose.yml`):

| | `lab-db` | `lab-gitea` |
|---|---|---|
| Образ | `postgres:16.6-alpine` (версія зафіксована) | `gitea/gitea:1.22.6` |
| Дані | volume `lab_pg-data` | volume `lab_gitea-data` (репозиторії, `app.ini`) |
| Мережі | `lab-backend` (**internal**) | `lab-backend` + `lab-frontend` |
| Порти на хості | **не публікуються** | `127.0.0.1:3000` (лише loopback) |
| Healthcheck | `pg_isready` | `curl /api/healthz` (перевіряє і БД) |
| restart | `unless-stopped` | `unless-stopped`, `depends_on: db healthy` |

**Рішення:**
- **Named volumes** з фіксованими іменами: дані живуть окремо від контейнерів. `docker compose down` + `up` створює нові контейнери, а дані лишаються.
- **Секрети** (пароль БД) лежать у `/opt/lab-app/.env` (0600, генерується скриптом, у git лише `.env.example`).
- **`lab-backend` — `internal: true`**: БД не має маршруту назовні, а до неї ходить лише Gitea по імені `db`.
- **Вбудований SSH Gitea вимкнено** (`DISABLE_SSH`): git працює по HTTP через nginx, тож зайвий порт не відкривається.
- **Реєстрацію вимкнено**: акаунти створює адміністратор (`gitadmin` створено скриптом).
- **`lab-app.service`** (systemd oneshot): `docker compose up -d --wait` після `docker.service`. Стек — це явний системний компонент, який можна `systemctl status/restart`, і він гарантовано піднімається після reboot, навіть якщо хтось перед цим зробив `docker compose stop` (`unless-stopped` у такому разі сам не підняв би).

**Перевірено:** створено репозиторій через API → `docker compose down` (контейнери видалено, volumes лишились) → `systemctl restart lab-app` → нові ID контейнерів, репозиторій на місці з початковою датою створення.

## 7. Інтеграція: DNS і reverse proxy

**DNS — dnsmasq на сервері** (`/etc/dnsmasq.d/student.lab.conf`):

| Ім'я | Тип | Значення |
|---|---|---|
| `lab-server.student.lab` | A | 192.168.56.10 |
| `lab-client.student.lab` | A | 192.168.56.20 |
| `www.student.lab` | CNAME | lab-server.student.lab |
| `app.student.lab` | CNAME | lab-server.student.lab |

- Обрано справжній DNS, а не `/etc/hosts` на кожній машині: імена централізовані, новий клієнт отримує їх автоматично, а несправність «перестало працювати ім'я» реалістична й діагностується (`dig`).
- dnsmasq слухає **лише** 192.168.56.10 (`interface=enp0s8`, `bind-dynamic`), тож він не конфліктує з systemd-resolved на 127.0.0.53. `bind-dynamic` підхоплює адресу, навіть якщо інтерфейс піднявся пізніше за dnsmasq (важливо для reboot).
- Він авторитетний тільки для `student.lab` (`local=/student.lab/`, `no-resolv`) і не є відкритим рекурсивним резолвером.

**Reverse proxy** — `server/nginx/app.conf`:
`http://app.student.lab` → nginx :80 → `proxy_pass http://127.0.0.1:3000` (upstream з keepalive, заголовки `Host`, `X-Real-IP`, `X-Forwarded-For/Proto`, `client_max_body_size 512m` для push великих репозиторіїв). Користувачу не потрібно знати ні порт 3000, ні те, що всередині Docker. Якщо backend недоступний, nginx віддає власну сторінку 502/503 з підказками для адміністратора.

## 8. Мережева безпека: таблиця портів і доступу

| Сервіс | Порт | Bind-адреса | Хто має доступ | Чому |
|---|---|---|---|---|
| **sshd** | 22/tcp | 0.0.0.0 (фільтр ufw) | 192.168.56.0/24 через enp0s8, `limit` | **зовнішній:** віддалене адміністрування і робота розробників; лише ключі, лише `sshusers` |
| **dnsmasq** | 53/udp+tcp | 192.168.56.10 | 192.168.56.0/24 | **зовнішній:** клієнтам потрібно розв'язувати `*.student.lab` |
| **nginx** | 80/tcp | 0.0.0.0 (фільтр ufw) | 192.168.56.0/24 | **зовнішній:** єдина точка входу до web-сторінки та застосунку |
| Gitea (HTTP) | 3000/tcp | **127.0.0.1** | лише nginx на цьому хості | **локальний:** напряму користувачам не потрібен |
| PostgreSQL | 5432/tcp | не опублікований; лише мережа `lab-backend` | лише контейнер Gitea | **внутрішній:** зв'язок між компонентами застосунку |
| systemd-resolved | 53 | 127.0.0.53/54 | лише сам сервер | **локальний:** резолвер ОС |
| Gitea SSH | 22 у контейнері | не опублікований, вимкнений | — | не потрібен |

**ufw** (`server/07-firewall.sh`): `default deny incoming`, `allow outgoing`, `deny routed`. Дозволено лише 22 (з rate-limit), 53, 80 **на інтерфейсі enp0s8 і лише з 192.168.56.0/24**. Логування `low` (у `journalctl -k` видно `[UFW BLOCK]`).

**Docker і ufw.** Docker додає власні iptables-правила для опублікованих портів **поза ланцюжками ufw**, тож правило ufw «заборонити 3000» не захистило б контейнер. Тому захист контейнерів зроблено на рівні bind-адрес: порт 3000 опубліковано лише на `127.0.0.1`, порт 5432 не опубліковано зовсім, а мережа БД — `internal`.

**Перевірено з клієнта** (`nmap -sS -p- 192.168.56.10`): відкриті тільки `22/tcp`, `53/tcp`, `80/tcp` (і `53/udp`), а 65532 інші порти `filtered`. Підключення до 3000 і 5432 не вдається. На сервері `ss -tlnp` показує `127.0.0.1:3000` і відсутність 5432. Контейнер БД не має виходу в мережу (`Network unreachable`).

## 9. Резервне копіювання та відновлення

**`/usr/local/sbin/lab-backup`** (`server/backup/lab-backup`), запуск через `lab-backup.timer` щодня о **02:30** (`Persistent=true`: якщо сервер у цей час був вимкнений, копія виконається після старту).

Кожна копія — окремий каталог `/var/backups/lab/YYYY-MM-DD_HHMM/` (root, 0700):

| Файл | Що в ньому | Покриває вимогу |
|---|---|---|
| `db.dump` | `pg_dump -Fc` бази Gitea (консистентний, без зупинки) | дані для відновлення застосунку |
| `gitea-data.tar.gz` | volume `lab_gitea-data`: git-репозиторії, вкладення, **`app.ini`** | дані + конфігурація застосунку |
| `projects.tar.gz` | `/srv/projects` з **правами, ACL, setgid** (`tar --acls --xattrs -p`) | project data |
| `config.tar.gz` | nginx, sshd, dnsmasq, ufw, systemd-юніти, NetworkManager, `/opt/lab-app` (compose + `.env`), сторінка сайту, скрипти, `/etc/passwd,group,shadow` | конфігурація сервісів і системи |
| `MANIFEST.txt`, `SHA256SUMS` | опис і контрольні суми | перевірка цілісності |

- Під час копіювання volume Gitea **зупиняється на кілька секунд**, щоб файли репозиторіїв відповідали дампу БД (`trap` гарантує повторний запуск навіть при помилці).
- Після створення кожен архів перевіряється (`gzip -t`, `pg_restore -l`).
- **Ротація:** останні 7 копій плюс найновіша копія кожного з 4 попередніх тижнів.
- `flock` не дає запустити дві копії одночасно; помилка → `lab-backup.service` failed → healthcheck покаже CRIT.

**`/usr/local/sbin/lab-restore`**:

```
sudo lab-restore list                                   # які є копії
sudo lab-restore show                                   # вміст останньої
sudo lab-restore project /srv/projects/devteam/plan.txt # файл або каталог (з ACL)
sudo lab-restore project all
sudo lab-restore config /etc/nginx/sites-available/app.conf
sudo lab-restore --to /tmp/peek config /etc/ssh/sshd_config.d/10-lab.conf  # розпакувати для перегляду, не чіпаючи систему
sudo lab-restore db | gitea-data | app                  # app = БД + репозиторії узгоджено
        --from 2026-11-21_1712                          # конкретна копія (за замовчуванням latest)
```
Перед відновленням перевіряються контрольні суми, а перед перезаписом скрипт питає підтвердження (`--yes`, щоб не питав).

**Продемонстровано:**
1. dev1 видалив `/srv/projects/devteam/plan.txt` → `lab-restore project …` → файл повернувся з тим самим md5, власником, групою `devteam` і ACL, dev2 знову може його редагувати.
2. Репозиторій Gitea видалено через API (HTTP 404) → `lab-restore app` → репозиторій є (HTTP 200), `git clone` з клієнта працює, історія комітів на місці.
3. Пошкоджено `app.conf` (`nginx -t` падає) → `lab-restore config …` → `nginx -t` OK, файл ідентичний версії в git.

> Обмеження: копії зберігаються на тому самому диску. Для production потрібна копія поза сервером (правило 3-2-1), наприклад `rsync` на іншу машину або в об'єктне сховище за таймером.

## 10. Моніторинг: healthcheck

```
sudo healthcheck            # повний звіт
sudo healthcheck --quiet    # лише проблеми + підсумок
```
Скрипт `/usr/local/bin/healthcheck` (`server/monitoring/healthcheck`) перевіряє:

| Група | Перевірки | WARN / CRIT |
|---|---|---|
| Ресурси | load average відносно кількості CPU, доступна RAM, swap | load > CPU / > 2×CPU; RAM < 15% / < 5% |
| Файлові системи | зайнятість і **inodes** для `/`, `/var/lib/docker`, `/var/backups`, `/srv` | ≥ 80% / ≥ 90% |
| Сервіси | ssh, nginx, docker, dnsmasq, lab-app, таймери backup і healthcheck: **active і enabled** (чи стартують після reboot); ufw активний; failed units | не enabled → WARN; не active → CRIT |
| Мережа | адреса на enp0s8; DNS напряму через dnsmasq і через резолвер ОС; правила ufw для 22/53/80 (є ALLOW, немає DENY); **неочікувані порти**, що слухають назовні | |
| Контейнери | state, health, кількість перезапусків; **зв'язок Gitea → db:5432** | |
| Застосунок | Gitea напряму (`127.0.0.1:3000/api/healthz`) **і** через nginx+DNS (`app.student.lab`), час відповіді; сторінка `www` містить KH-24 | |
| Дані | права й ACL проєктної зони; вік останнього backup і результат останнього запуску | > 26 год / > 50 год |

Кожен рядок `WARN`/`CRIT` містить підказку, куди дивитися далі. Підсумок — `OK` / `ПОТРЕБУЄ УВАГИ` / `КРИТИЧНО`, код виходу **0 / 1 / 2** (можна використовувати в скриптах).

Перевірка Gitea окремо напряму і окремо через nginx одразу локалізує проблему: якщо падає лише `app.student.lab`, причина в nginx/DNS/ufw, а якщо обидві, то в застосунку.

**Автоматично:** `healthcheck.timer` запускає перевірку кожні 5 хв. Результат іде в журнал (`journalctl -t healthcheck`) і в `/var/lib/healthcheck/last.txt`, який показується при кожному SSH-вході (MOTD `/etc/update-motd.d/99-lab-health`). Адміністратор одразу бачить стан, щойно залогінився.

## 11. Runbook: діагностика несправностей

Загальний алгоритм: **симптом → локалізація → root cause → усунення → перевірка**. Перший крок завжди один:

```
sudo healthcheck --quiet       # що саме не так
```
Далі — за сценарієм. Позначка ✅ означає, що сценарій відпрацьовано наживо під час побудови (крок 8 у PLAN.md).

### 11.1 Застосунок перестав бути доступним ✅
- **Симптом:** `http://app.student.lab` не відкривається (502/504 або timeout).
- **Локалізація** — йдемо від клієнта всередину:
  ```
  client$ dig +short app.student.lab                 # 1) ім'я → 192.168.56.10?
  client$ curl -sI http://www.student.lab/           # 2) nginx/порт 80 живі?
  server$ curl -s 127.0.0.1:3000/api/healthz         # 3) Gitea відповідає напряму?
  server$ sudo docker compose --project-directory /opt/lab-app ps   # 4) стан контейнерів
  server$ sudo tail /var/log/nginx/app.error.log     # "connect() failed (111)" = backend лежить
  ```
- **Типові причини:** контейнер зупинено або впав (→ 11.8); nginx зупинено (→ 11.2); Gitea не бачить БД (→ 11.3); заблоковано порт (→ 11.9); не працює DNS (→ 11.4).
- **Перевірка:** `sudo healthcheck` = OK, `curl -I http://app.student.lab` з клієнта = 200.

### 11.2 Один із сервісів не запускається ✅
- **Симптом:** healthcheck: `[CRIT] <сервіс> ... failed`, у `failed units` є сервіс.
- **Локалізація:**
  ```
  systemctl status <unit>            # останні рядки журналу та exit code
  journalctl -u <unit> -b -n 50      # повний журнал з моменту завантаження
  ```
- **Root cause — перевірка конфігу самим сервісом:**
  | Сервіс | Перевірка |
  |---|---|
  | nginx | `sudo nginx -t` (покаже файл і рядок) |
  | sshd | `sudo sshd -t` |
  | dnsmasq | `sudo dnsmasq --test --conf-dir=/etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new` ⚠️ без `--conf-dir` тест **не читає** `/etc/dnsmasq.d` і завжди каже OK (знайдено під час drill) |
  | docker compose | `sudo docker compose --project-directory /opt/lab-app config -q` |
  | systemd-юніт | `systemd-analyze verify /etc/systemd/system/<unit>` |
  Також: порт зайнятий іншим процесом (`sudo ss -tlnp | grep :80`), немає місця на диску (→ 11.7).
- **Усунення:** виправити конфіг або повернути з git чи з backup (`lab-restore config <шлях>`), потім `systemctl restart <unit>`.
- **Перевірка:** `systemctl is-active <unit>`, `sudo healthcheck`.
- *Drill:* у dnsmasq додано некоректний `host-record` → сервіс failed, DNS не працює. `dnsmasq --test --conf-dir=…` вказав `Bad host-record at line 22`. Конфіг повернуто з репозиторію.

### 11.3 Застосунок не може звернутися до БД ✅
- **Симптом:** `app.student.lab` дає 500/424; healthcheck: `[CRIT] app -> db`, `gitea backend` не відповідає.
- **Локалізація:**
  ```
  sudo docker ps -a --filter name=lab-                              # db running/healthy?
  sudo docker logs --tail 30 lab-gitea | grep -i -E 'database|postgres|dial'
  sudo docker exec lab-gitea nc -zv db 5432                         # мережевий шлях
  sudo docker network inspect lab-backend -f '{{range .Containers}}{{.Name}} {{end}}'  # чи обидва в мережі
  sudo docker exec lab-db pg_isready -U gitea
  ```
- **Типові причини:** контейнер db зупинено; db від'єднано від `lab-backend`; змінено пароль у `.env` без зміни в БД; пошкоджено або видалено volume `lab_pg-data`.
- **Усунення:** `sudo systemctl restart lab-app` (compose заново під'єднає мережі й підніме db). Якщо дані пошкоджено: `sudo lab-restore db`.
- **Перевірка:** `sudo docker exec lab-gitea nc -z db 5432 && echo ok`, healthcheck OK.
- *Drill:* `docker network disconnect lab-backend lab-db` → healthcheck: `app -> db CRIT`, nginx віддав 424. Після `docker network connect --alias db lab-backend lab-db` усе OK.

### 11.4 Перестало працювати мережеве ім'я ✅
- **Симптом:** за IP (`http://192.168.56.10`) працює, а за `app.student.lab` ні (`Could not resolve host`).
- **Локалізація** (на клієнті):
  ```
  dig app.student.lab @192.168.56.10      # питаємо dnsmasq напряму
  resolvectl status enp0s8               # чи стоїть DNS 192.168.56.10 і домен ~student.lab
  resolvectl query app.student.lab
  ```
  На сервері: `systemctl status dnsmasq`, `sudo ss -ulnp | grep :53`, `sudo ufw status | grep 53`.
- **Типові причини:** dnsmasq упав або в ньому помилка конфігу (→ 11.2); прибрано запис; ufw блокує 53; на клієнті зник DNS-сервер або routing domain у профілі NM (`nmcli con show lab-hostonly | grep ipv4.dns`); кеш (`resolvectl flush-caches`).
- **Усунення:** виправити конфіг, `systemctl restart dnsmasq`; на клієнті `sudo nmcli con mod lab-hostonly ipv4.dns 192.168.56.10 ipv4.dns-search ~student.lab && sudo nmcli con up lab-hostonly`.
- **Перевірка:** `dig +short app.student.lab` → 192.168.56.10.

### 11.5 Клієнт не може підключитися до сервера ✅
- **Симптом:** `ssh lab-admin` → `Connection refused` / `timed out` / `No route to host` / `Permission denied`.
- **Локалізація — що саме каже помилка:**
  | Помилка | Що означає | Де шукати |
  |---|---|---|
  | `No route to host`, ping не йде | L2/L3: немає мережі | IP на обох (`ip -br a`), адаптер VirtualBox (host-only, той самий vboxnet, кабель підключено), `ip neigh` (INCOMPLETE = машини не бачать одна одну) |
  | `Connection timed out` | пакети відкидаються | ufw (`sudo ufw status numbered`, `journalctl -k | grep 'UFW BLOCK'`) |
  | `Connection refused` | хост є, порт ніхто не слухає | `systemctl status ssh.socket ssh.service`, `ss -tlnp | grep :22` |
  | `Permission denied (publickey)` | мережа OK, автентифікація ні | `journalctl -u ssh -n 20` (не той ключ, користувач не в `sshusers`, права на `~/.ssh` (700) / `authorized_keys` (600)) |
  | `Could not resolve hostname` | DNS | → 11.4, тимчасово `ssh sysadmin@192.168.56.10` |
- **Усунення:** відповідно до причини; `sudo systemctl start ssh.socket`.
- **Перевірка:** `ssh lab-admin hostname`.
- *Drill:* зупинено `ssh.socket` і `ssh.service` → клієнт отримав `Connection refused` (хост живий, порт закритий), healthcheck: `[CRIT] ssh`. Після `systemctl start ssh.socket` вхід працює.

### 11.6 Розробник втратив доступ до проєкту ✅
- **Симптом:** `ls /srv/projects/devteam: Permission denied` або не може змінити файл.
- **Локалізація:**
  ```
  id dev2                                   # чи є devteam у групах
  getent group devteam
  stat -c '%A %a %U:%G' /srv/projects/devteam   # очікується drwxrws--- 2770 root:devteam
  getfacl -p /srv/projects/devteam              # default ACL на місці?
  getfacl -p /srv/projects/devteam/<файл>       # mask не обрізана?
  ```
  healthcheck покаже `[WARN] project area`, якщо зламано права каталогу.
- **Типові причини:** користувача прибрали з групи; змінено права (`chmod`); зіпсовано ACL (`setfacl -b`); файл скопійовано з `cp -p`/`mv` з іншого місця зі старими правами чи групою. Важливо: **нова група діє лише після повторного входу** (`newgrp` або relogin).
- **Усунення:**
  ```
  sudo gpasswd -a dev2 devteam
  sudo chmod 2770 /srv/projects/devteam
  sudo setfacl -R -m g:devteam:rwX,o::--- /srv/projects/devteam
  sudo setfacl -R -d -m u::rwX,g::rwX,g:devteam:rwX,o::--- /srv/projects/devteam
  sudo chgrp -R devteam /srv/projects/devteam
  ```
  або просто `sudo bash server/03-users.sh` (ідемпотентний).
- **Перевірка:** `sudo -u dev2 -i touch /srv/projects/devteam/x && ls -l` (група devteam).
- *Drill:* `gpasswd -d dev2 devteam` + `chmod 2750` → dev2 `Permission denied`, `id dev2` без devteam, healthcheck WARN. Виправлено командами вище.

### 11.7 Закінчується місце на файловій системі ✅
- **Симптом:** сервіси падають з `No space left on device`, БД не пише, healthcheck: `[CRIT] fs /`.
- **Локалізація:**
  ```
  df -h ; df -i                                  # місце чи inodes?
  sudo du -xh --max-depth=1 / | sort -h | tail   # який каталог (далі вглиб)
  sudo find / -xdev -type f -size +500M -exec ls -lh {} +
  sudo journalctl --disk-usage
  sudo docker system df                          # образи, volumes, build cache
  sudo du -sh /var/backups/lab /var/log
  sudo lsof +L1                                  # видалені, але ще відкриті файли (місце не звільнилось)
  ```
- **Типові причини:** великі логи, старі образи/контейнери Docker, накопичені backup, випадкові великі файли.
- **Усунення:** `sudo journalctl --vacuum-size=200M`, `sudo docker image prune`, видалити зайве (обережно — спочатку подивитися, що це), перезапустити процес, що тримає видалений файл. Backup ротуються автоматично.
- **Перевірка:** `df -h /` < 80%, healthcheck OK.
- *Drill:* `fallocate` на 6.8 ГБ у `/var/tmp` → `/` 96%, healthcheck CRIT. `du` одразу вказав на `/var/tmp`, після видалення 62%.

### 11.8 Контейнер завершив роботу ✅
- **Симптом:** healthcheck: `[CRIT] lab-gitea exited (exit N)`; застосунок дає 502.
- **Локалізація:**
  ```
  sudo docker ps -a --filter name=lab-
  sudo docker logs --tail 50 lab-gitea         # чому впав
  sudo docker inspect -f '{{.State.ExitCode}} {{.State.OOMKilled}} {{.State.Error}}' lab-gitea
  sudo journalctl -u docker -n 30
  ```
  Exit 0 означає, що його зупинили вручну; 137 — kill або OOM; 1/2 — помилка застосунку (конфіг, БД, права на volume).
- **Усунення:** `sudo systemctl restart lab-app` (= `docker compose up -d --wait`). Якщо падає циклічно, читати `docker logs`, виправити причину (часто БД → 11.3, диск → 11.7).
- **Перевірка:** `docker ps` → `healthy`, healthcheck OK.
- *Drill:* `docker stop lab-gitea` → healthcheck CRIT (`exited (exit 0)`, backend 000, nginx 502). `systemctl restart lab-app` → OK.

### 11.9 Мережевий доступ блокується ✅
- **Симптом:** з клієнта ping працює, а сервіс ні (`timed out`, не `refused`).
- **Локалізація:**
  ```
  sudo ufw status numbered                       # чи немає DENY вище за ALLOW
  sudo journalctl -k --since -10min | grep 'UFW BLOCK'   # що саме відкидається (SRC, DPT)
  sudo iptables -S DOCKER-USER                   # для контейнерів
  client$ nmap -p 22,53,80 192.168.56.10
  ```
  healthcheck: `[CRIT] ufw :80 є DENY/REJECT правило` або `немає правила ALLOW`.
- **Усунення:** `sudo ufw delete <номер>`. ⚠️ Правило без `from` створюється і для IPv4, і для IPv6, тож видаляти потрібно обидва (`ufw status numbered` після кожного delete). Або повернути весь набір: `sudo bash server/07-firewall.sh`.
- **Перевірка:** `curl` з клієнта, healthcheck OK.
- *Drill:* `ufw insert 1 deny … port 80` → клієнт: app=000 при живому ping. Після видалення IPv4-правила healthcheck **продовжував показувати CRIT**: лишилося `80/tcp (v6) DENY`. Тобто healthcheck виявив неповне виправлення.

### 11.10 Після reboot один із компонентів не запустився ✅
- **Симптом:** після перезавантаження щось недоступне.
- **Локалізація:**
  ```
  sudo healthcheck                         # покаже "працює, але ... disabled — не стартує після reboot"
  systemctl --failed
  systemctl is-enabled nginx docker dnsmasq lab-app ssh.socket ufw lab-backup.timer healthcheck.timer
  journalctl -b -p err                     # помилки цього завантаження
  systemd-analyze critical-chain lab-app.service   # порядок і час запуску
  nmcli con show --active                  # чи піднявся lab-hostonly
  ```
- **Типові причини:** юніт `disabled`; сервіс стартує раніше, ніж готова залежність (мережа, docker); `restart: no` у контейнера; профіль NM не має `autoconnect`.
- **Усунення:** `sudo systemctl enable --now <unit>`; для стеку — `systemctl enable lab-app` (він має `After=docker.service network-online.target`).
- **Перевірка:** reboot → `sudo healthcheck` (див. розділ 12).
- *Drill:* `systemctl disable nginx` → healthcheck: `[WARN] nginx працює, але disabled — не стартує після reboot`. Проблема видна ще **до** перезавантаження.

## 12. Reboot-тест

_Заповнюється після кроку 9 (див. PLAN.md)._

## 13. Структура репозиторію і розгортання

```
README.md  PLAN.md  task.txt
server/
  lab.env                 спільні параметри (IP, домен, імена)
  lib.sh                  спільні функції скриптів
  00-bootstrap.sh         пакети (openssh-server nginx dnsmasq acl curl jq dnsutils)
  01-network.sh           статична IP enp0s8, hostname
  02-admin-ssh.sh         sysadmin, sshusers, sshd hardening, блокування root
  03-users.sh             dev1/dev2/guest, devteam, /srv/projects, HOME_MODE
  04-web.sh               nginx: сайти, сторінка, hardening
  05-dns.sh               dnsmasq: зона student.lab
  06-app.sh               /opt/lab-app, .env, lab-app.service, адмін Gitea
  07-firewall.sh          ufw
  08-backup.sh            lab-backup/lab-restore + timer
  09-monitoring.sh        healthcheck + timer + MOTD
  ssh/ nginx/ www/ dnsmasq/ app/ systemd/ backup/ monitoring/ keys/   — конфіги, що встановлюються
client/
  setup-client.sh         статична IP .20, hostname, DNS, інструменти
  ssh_config              аліаси lab-admin / lab-dev1 / lab-dev2
tests/
  verify.sh               наскрізна перевірка з клієнта
```

- **Git — джерело правди.** Скрипти копіюють конфіги з репозиторію в `/etc`, `/opt`, `/usr/local` (`install`). Зміна конфігу — це зміна в репозиторії + повторний запуск відповідного скрипта.
- **Скрипти ідемпотентні:** повторний запуск приводить систему до того самого стану (наприклад, після «зламаних» прав).
- **Секрети не в git:** `/opt/lab-app/.env`, `/root/lab-initial-passwords`, приватні ключі (`.gitignore`). У git лише публічні ключі.

Розгортання з нуля (сервер): `sudo bash server/00-bootstrap.sh` … `09-monitoring.sh` по черзі. Клієнт: `sudo bash client/setup-client.sh` (через `nohup`, бо зміна IP розриває SSH-сесію).

## 14. Чекліст демонстрації на захисті

| # | Що показати | Команда |
|---|---|---|
| 1 | Топологія, IP, імена | `ip -br a`, `hostnamectl` на обох; `ping lab-server.student.lab` |
| 2 | Сторінка студента з клієнта | браузер `http://www.student.lab` |
| 3 | Застосунок за іменем | браузер `http://app.student.lab` (gitadmin) |
| 4 | SSH лише ключами | `ssh lab-admin`; `ssh -o PubkeyAuthentication=no sysadmin@lab-server.student.lab` → denied; `ssh root@…` → denied |
| 5 | Спільна зона та ізоляція | `ssh lab-dev1` → створити файл → `ssh lab-dev2` → редагувати; `sudo -u guest ls /srv/projects/devteam` → denied |
| 6 | Закриті порти | `sudo nmap -sS -p- 192.168.56.10` з клієнта; `sudo ss -tlnp` на сервері |
| 7 | Persistence | створити repo → `sudo docker compose --project-directory /opt/lab-app down && sudo systemctl restart lab-app` → repo на місці |
| 8 | Backup / restore | `sudo lab-restore list`; видалити файл/repo → `lab-restore project …` / `lab-restore app` |
| 9 | Моніторинг | `sudo healthcheck`; `docker stop lab-gitea` → CRIT → `systemctl restart lab-app` |
| 10 | Reboot | `sudo reboot` → `sudo healthcheck` + `bash tests/verify.sh` з клієнта |
