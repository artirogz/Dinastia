# 09. Сервер, деплой, бэкапы

Один российский VPS, всё в Docker Compose: `caddy`, `web`, `worker`, `postgres`, одноразовый `migrate`.
Файлы лежат в `infra/`. Этот документ описывает, как поднять сервер с нуля, как выкатывать версии,
как откатываться и как проверять, что бэкапы настоящие.

Версионные вещи (образы, флаги Docker, панели провайдеров) сверяй с актуальной документацией:
они меняются быстрее, чем этот текст.

## 1. Выбор VPS

Требование одно: сервер физически в России (персональные данные, `docs/03-auth-and-security.md`).
Подходят Timeweb Cloud, Beget, Selectel. Выбор по цене и удобству панели, на архитектуру он не влияет.

Стартовая конфигурация: 2 vCPU, 4 ГБ RAM, 40–60 ГБ NVMe, Ubuntu 24.04 LTS. Откуда цифры: в работе
`web` (Next.js standalone) занимает 300–500 МБ, `worker` 100–200 МБ, `postgres` на базе в десятки
тысяч строк 200–300 МБ, `caddy` до 50 МБ, итого около 1,5 ГБ; трафик мини-аппа на тысячу учеников
это единицы запросов в секунду, одно ядро простаивает. 4 ГБ, а не 2, нужны из-за `next build`,
который `infra/deploy.sh` гоняет на самом сервере: пик сборки 1,5–2,5 ГБ, и на 2 ГБ без swap он
падает по памяти. Swap 2 ГБ ставится в §2 как страховка. Если сборка на сервере всё равно падает или
идёт дольше 15 минут, образ собирается в GitHub Actions (`docker/build-push-action`, образ в GHCR) и
`deploy.sh` только скачивает его: это запасной путь, не стартовый. Видео на этом сервере не раздаётся (оно на
видеохостинге или в HLS-хранилище, `docs/05-video-delivery.md`), поэтому диск нужен только под
систему, образы Docker, базу и материалы уроков.

Бюджет диска (оценка, после первого выката сверить с `docker system df` и `du -sh /srv/courses/*`):
система и Docker около 5 ГБ; образы приложения до 4 ГБ (`deploy.sh` держит пять релизов по 0,5–0,8 ГБ);
кэш сборки до 3 ГБ (`deploy.sh` удаляет слои старше недели); база и 14 суточных дампов до 2 ГБ на
старте; остальное занимают материалы уроков в `/srv/courses/media`. Диска на 40 ГБ хватает, пока медиа
меньше 20 ГБ.

Расти по замеру, не заранее: `docker stats` и `free -m` после выката покажут реальный расход; тариф у
российских провайдеров меняется в панели без переезда. Переход на 4 vCPU / 8 ГБ и диск от 160 ГБ
оправдан только в двух случаях: вариант `hls` с файлами видео на самом сервере (тогда диск = размер
всех уроков плюс запас в полтора раза, и трафик канала считается отдельно) или сборка образа стала
мешать работающему приложению (альтернатива дешевле: собирать образ на ноутбуке и загружать готовый).

Заранее: попросить у провайдера включить автоматические снимки диска (это дополнение к бэкапам из
раздела 7, не замена).

## 2. Первичная настройка сервера

Под root, один раз.

```bash
# swap 2G: next build peaks at 1.5-2.5 GB and must not take the app down on a 4 GB box
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# user for deployments, ssh key only
adduser --disabled-password --gecos "" deploy
usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh && chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys
echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy

# ssh: no root login, no passwords
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
```

Перед закрытием текущего сеанса открой второй терминал и проверь `ssh deploy@<ip>`. Только после этого
закрывай root-сеанс.

Межсетевой экран, защита от подбора, автообновления:

```bash
apt update && apt -y upgrade
apt -y install ufw fail2ban unattended-upgrades curl git rclone
ufw default deny incoming && ufw default allow outgoing
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp
ufw --force enable
systemctl enable --now fail2ban
dpkg-reconfigure -plow unattended-upgrades
```

Порт 5432 наружу не открывается: в `docker-compose.yml` Postgres сидит во внутренней сети `backend`
и не публикует портов.

## 3. Docker

Ставим по инструкции с официального сайта Docker для Ubuntu (apt-репозиторий Docker, не пакет
`docker.io`); шаги в документации меняются, поэтому не копируем их сюда.

```bash
sudo usermod -aG docker deploy   # then log out and in again
docker version && docker compose version
```

Ротация логов контейнеров уже настроена в `docker-compose.yml` (драйвер `json-file`, `max-size` и
`max-file`), ничего добавлять в `/etc/docker/daemon.json` не нужно.

## 4. Домен и TLS

1. Купи домен или заведи поддомен, например `courses.example.ru`.
2. В DNS добавь A-запись `app.<домен>` на IP сервера. Если DNS у регистратора с долгим кэшем,
   сделай это за сутки до запуска.
3. В `infra/.env` задай `DOMAIN=<домен>` (без `app.`) и `ACME_EMAIL=<почта>`.

Caddy сам получит сертификат Let's Encrypt при первом запуске и будет продлевать его. Условие: порты
80 и 443 доступны снаружи и A-запись уже указывает на сервер. Если сертификат не выпустился, смотри
`docker compose -f infra/docker-compose.yml logs caddy`: чаще всего причина в DNS или закрытом порту.

В `Caddyfile` включены HSTS, `nosniff`, `Referrer-Policy` и CSP с `frame-ancestors` для веб-клиентов
Telegram. `X-Frame-Options` не ставится намеренно: он заблокировал бы Telegram Web. Список разрешённых
доменов клиентов Telegram сверь с актуальной документацией Telegram.

## 5. Репозиторий и `.env` на сервере

```bash
sudo mkdir -p /opt/courses /srv/courses/media /srv/courses/backups
sudo chown -R deploy:deploy /opt/courses /srv/courses
sudo chown 1001:1001 /srv/courses/media      # uid of the "app" user inside the image
cd /opt/courses
git clone <repository-url> .
chmod +x infra/*.sh
cp infra/.env.example infra/.env
chmod 600 infra/.env
```

`chown 1001` нужен потому, что приложение в контейнере работает не от root (пользователь `app`, uid 1001)
и должно писать в каталог медиафайлов.

В `infra/.env` заполни все пустые значения. Комментарий к каждой переменной стоит над ней в
`infra/.env.example`. Сгенерировать секреты:

```bash
openssl rand -hex 32     # SESSION_SECRET, TG_WEBHOOK_SECRET, KINESCOPE_AUTH_SECRET, POSTGRES_PASSWORD
```

Проверь, что в `.env` стоит `DEV_LOGIN=0` (`NODE_ENV=production` compose задаёт сам): вход без Telegram в проде не
должен существовать (`scripts/smoke.mjs` проверяет это сам: `POST /api/dev/login` обязан отвечать 404).

`.env` живёт только на сервере и в менеджере паролей владельца. В git его нет.

## 6. Первый деплой

```bash
cd /opt/courses
infra/deploy.sh
```

Что делает скрипт, по шагам:

1. `git pull --ff-only` из `main`. Устанавливаемая версия = короткий хеш `HEAD` или коммит из
   `--sha <commit>`.
2. Сборка образа `courses-app:<hash>` (один образ для `web`, `worker`, `migrate` и импорта) из временной
   копии репозитория на этом коммите (`git worktree`), рабочая копия в `/opt/courses` остаётся на `main`.
   Сборка падает, если в образе нет любого из четырёх входов `dist/` или пакета, который они импортируют
   (`infra/check-runtime.mjs`, ниже).
3. Запуск Postgres и ожидание готовности.
4. Бэкап базы перед миграциями (`infra/backup.sh`; на самом первом деплое база пустая, это нормально).
5. Версия записывается в `infra/.release/candidate`, миграции идут из её образа.
6. Запуск `web` и `worker` на новой версии, ожидание, пока оба станут healthy. Тег `courses-app:current`
   переставляется на запущенную версию: это псевдоним для `restore.sh` и `docker compose logs`, которые
   запускаются без версии.
7. Smoke-проверка боевого адреса (`scripts/smoke.mjs`) в одноразовом контейнере Node. Вывод
   сохраняется в `infra/.last-smoke.txt` (на сервере, не в git): вердикт выката читается из этого
   файла, а не из кода возврата скрипта.
8. Успех: прошлая хорошая версия переезжает в `infra/.release/previous`, новая записывается в
   `infra/.release/current`, `candidate` удаляется; остаются пять последних образов, кэш сборки старше
   недели удаляется.

Скрипт остановится на первой ошибке. Если новая версия не стала healthy или не прошла smoke, скрипт
сам поднимает версию из `infra/.release/current` (последнюю, прошедшую smoke), проверяет её тем же
smoke, пишет причину в `infra/.release/failed` и завершается с ошибкой. `current` и `previous` при этом
не меняются. Если хорошей версии ещё нет (провалился самый первый выкат), новая остаётся работать и
чинится следующим выкатом.

Для проверки работоспособности скрипту нужны в приложении:

- маршрут `GET /api/health` (200, если жива база);
- скрипт `build:server` в `package.json`, ровно такой:
  `esbuild worker/index=src/worker/index.ts db/migrate=src/db/migrate.ts scripts/import-content=scripts/import-content.ts --bundle --platform=node --format=esm --target=node24 --packages=external --outdir=dist`.
  Входы заданы парами «выход=вход», поэтому файлы получаются ровно там, где их зовут compose и этот
  документ: `dist/worker/index.js`, `dist/db/migrate.js`, `dist/scripts/import-content.js` (вариант
  `--outbase=.` дал бы `dist/src/worker/index.js`). В бандлы попадает только наш код, npm-пакеты остаются
  внешними и берутся из `node_modules` образа: Dockerfile ставит туда все `dependencies` из
  `package.json` (`npm ci --omit=dev`), поэтому пакет, который нужен воркеру или импорту, обязан стоять в
  `dependencies`: пакет из `devDependencies` в образ не попадёт. `migrate.js` берёт SQL из папки `drizzle/` рядом с `dist/`,
  `drizzle.config.ts` пишет туда же;
- файл `/tmp/worker-heartbeat`, который воркер обновляет каждые 30 секунд.

Все четыре входа и оба сигнала существуют с M0 (`start-project` §4): `GET /api/health`, `migrate.ts`, каркас
воркера с heartbeat, заглушка импорта (код 1 до M3) и заглушка админ-CLI `scripts/admin.ts` (код 1 до M4). Реальная работа появляется по
этапам (`docs/08-roadmap.md`): импорт на M3, задача `payments-reconcile` на M4, остальные задачи воркера
на M5. `build:server` зелёный с первого дня, поэтому `deploy.sh` проходит на любом этапе; импорт контента
на сервере до M3 просто сообщает, что ещё не реализован.

Проверка образа при сборке (`infra/check-runtime.mjs`, последний шаг Dockerfile) ничего не запускает:
`node --check` на четырёх файлах `dist/` и сверка каждого импортируемого ими пакета с
`node_modules/<пакет>/package.json`. Импортировать бандлы ради проверки нельзя, импорт запустил бы
воркер или миграции.

### Импорт контента на сервере

`content/` попадает в образ при сборке, поэтому порядок такой: правка в git, `infra/deploy.sh`, импорт.
Импорт запускается на сервере вручную, внутри образа, где npm-скриптов нет:

```bash
cd /opt/courses
docker compose -f infra/docker-compose.yml --env-file infra/.env run --rm web node dist/scripts/import-content.js
```

Ключ `--dry-run` показывает, что изменится, и ничего не пишет. Повторный запуск на тех же файлах
ничего не меняет.

### Подключение внешних сервисов (один раз, после первого успешного деплоя)

Telegram webhook:

```bash
set -a; . infra/.env; set +a
curl -sS "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
  --data-urlencode "url=https://app.${DOMAIN}/api/tg/webhook" \
  --data-urlencode "secret_token=${TG_WEBHOOK_SECRET}" \
  --data-urlencode 'allowed_updates=["message","callback_query","my_chat_member"]'
curl -sS "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo"
```

В ответе `getWebhookInfo` должны быть наш URL, `pending_update_count` около нуля и пустой `last_error_message`.
Сверь имена параметров `setWebhook` с актуальной документацией Bot API.

Mini App в BotFather: `/mybots` → бот → Bot Settings → Menu Button, URL `https://app.<домен>/`.
Для прямой ссылки `t.me/<бот>/app` задаётся Main Mini App там же; точные пункты меню BotFather
уточни по документации Telegram.

ЮKassa: в личном кабинете магазина (раздел с уведомлениями или HTTP-уведомлениями, название уточни
по документации ЮKassa) включить события `payment.succeeded`, `payment.canceled`, `refund.succeeded`
и указать URL `https://app.<домен>/api/payments/webhook`. Подписка делается руками в кабинете,
поэтому есть фоновая сверка (`docs/04-payments-yookassa.md` §4): если уведомление не пришло,
платёж подтянется сам в течение нескольких минут.

После этого прогони `node scripts/smoke.mjs https://app.<домен>` с ноутбука: все строки должны быть PASS.

## 7. Обычный выкат

Код попал в `main` (через PR, после ревью) → на сервере:

```bash
ssh deploy@<ip>
cd /opt/courses && infra/deploy.sh
```

Выкатывать лучше пакетом: накопил несколько готовых задач, выкатил один раз, проверил боевой адрес.
Выкат на каждую мелкую правку множит риск и ручную работу.

Миграции обязаны быть совместимыми с предыдущей версией кода: сначала добавляем колонку (nullable
или с дефолтом), в следующем релизе начинаем её использовать, ещё в одном удаляем старое. Тогда
откат на одну версию назад безопасен. Миграция, ломающая прошлую версию, требует отдельного плана и
бэкапа перед ней, и её нельзя катить в пятницу вечером.

### Откат

Неудачный выкат откатывается сам (раздел 6): работать остаётся последняя версия, прошедшая smoke.
Ручной откат нужен, когда версия прошла smoke, но ошибка нашлась позже:

```bash
infra/deploy.sh rollback                 # start infra/.release/previous, the good release before current
infra/deploy.sh --sha <commit>           # start any earlier commit; builds it if the image is gone
```

Состояние релизов лежит в `infra/.release/` на сервере:

| Файл | Что значит |
|---|---|
| `current` | последняя версия, прошедшая smoke; она работает, когда выката нет |
| `previous` | хорошая версия перед `current`, цель `rollback` |
| `candidate` | версия, которая ставится прямо сейчас; после успеха удаляется |
| `failed` | последняя версия, не прошедшая проверку, и причина |

Пример: работает B (`current=B`, `previous=A`), выкат C провалил smoke. Скрипт поднимает B, пишет C в
`failed`, `current` и `previous` остаются B и A. Если потом выяснится, что сломан сам B, `rollback`
поднимет A, `current` станет A, а `previous` очистится: шаг назад делается один, дальше только
`--sha <commit>`.

`rollback` и `--sha` проверяют версию тем же smoke. Миграции назад не откатываются: именно поэтому
они должны оставаться совместимыми на одну версию. `--sha` на коммит старше одной версии назад
допустим только если миграции между ними совместимы с ним; иначе нужен restore (раздел 8).
Образа нужной версии нет на сервере (прунинг держит пять последних плюс `current` и `previous`):
`--sha` пересоберёт его из временной копии репозитория, рабочая копия остаётся на `main`.

Если сломались данные (а не код), откат версии не поможет: нужен restore из бэкапа, раздел 8.

## 8. Бэкапы

Что копируется:

1. База: `pg_dump -Fc` раз в сутки в 03:00 и перед каждой миграцией.
2. Каталог медиафайлов (`/srv/courses/media`: обложки, материалы, HLS-файлы, если они у нас). В хранилище
   `<remote>/media/current` повторяет каталог один в один (`rclone sync`); файл, удалённый или заменённый
   на сервере, при этой же синхронизации переезжает в `<remote>/media/deleted/<дата-время>/`
   (`--backup-dir`) и лежит там `BACKUP_RETENTION_DAYS` дней, потом удаляется. Так удаление по `/forget`
   доезжает до копии следующей ночью и уходит из бэкапов через 14 дней.
3. Файл `infra/.env` в базу и бэкапы не входит: он хранится в менеджере паролей владельца.

Ключи медиафайлов неизменяемы (`docs/02-data-model.md`, `file_key`): новый файл всегда получает новый
ключ, старый ключ никогда не перезаписывается. Поэтому набор файлов на дату любого дампа в пределах
срока хранения восстанавливается точно: `media/current` плюс папки `media/deleted/<дата-время>` позже
даты дампа.

Настройка cron под пользователем `deploy`:

```bash
crontab -e
# 03:00 every night
0 3 * * * /opt/courses/infra/backup.sh >> /var/log/courses-backup.log 2>&1
```

(файл `/var/log/courses-backup.log` создай заранее: `sudo touch ... && sudo chown deploy ...`).

Куда уезжает копия: S3-совместимое хранилище российского провайдера (Selectel, Timeweb, Yandex Object
Storage и аналоги), через `rclone`. Один раз под `deploy`:

```bash
rclone config           # new remote, type s3, provider "Other"; endpoint and keys from the provider panel
rclone lsd <remote>:    # must list the bucket
```

В `infra/.env` задай `BACKUP_RCLONE_REMOTE=<remote>:<bucket>/courses`. Без этой переменной скрипт
честно предупредит, что копия лежит только на самом сервере: копия на том же диске не защищает от потери
сервера.

Хранение: 14 дней (`BACKUP_RETENTION_DAYS`), и локально, и в хранилище, и для удалённых медиафайлов.
Скрипт после дампа проверяет его через `pg_restore --list` и только потом считает бэкап успешным. Если
каталог медиа на сервере пуст, а копия в хранилище нет, скрипт останавливается: это потерянный диск или
отвалившееся монтирование, и синхронизация пустого каталога увела бы всю копию в `deleted/`.

Контроль «бэкап вообще идёт»: в Uptime Kuma (раздел 10) создай монитор типа Push, а его URL
положи в `BACKUP_HEARTBEAT_URL`. Скрипт стучится туда только после полного успеха. Не пришёл стук
в течение суток, монитор краснеет и присылает сообщение в Telegram.

### Тренировка восстановления: раз в месяц

Бэкап, который ни разу не восстанавливали, считается несуществующим.

```bash
ls -t /srv/courses/backups/*.dump | head -1                 # the newest dump
infra/restore.sh /srv/courses/backups/<file>.dump --drop    # restore into a scratch database, print row counts, drop it
```

Скрипт восстанавливает дамп во временную базу `<имя>_restore` рядом с боевой, не трогая её, печатает
число строк в основных таблицах (users, courses, lessons, orders, entitlements, progress) и удаляет
временную базу. Сверь числа с боевыми: расхождение в пределах суток нормально, нули означают сломанный
бэкап. Результат запиши в `PROJECT-STATE.md` строкой журнала с датой.

### Восстановление после аварии

Порядок важен: сначала копия рядом, потом переключение, отправки последними.

1. База. `infra/restore.sh <dump> --into-live`. Скрипт восстанавливает дамп в `<имя>_restore`, не трогая
   боевую базу (сбой `pg_restore` на этом шаге ничего не меняет), печатает числа строк копии и боевой базы
   и список того, что воркер отправил бы повторно (рассылки в `sending`, получатели `pending`, шаги
   прогревов, которым пришёл срок, заказы `pending`). Затем просит набрать имя базы. После подтверждения
   останавливает `web` и `worker`, переименовывает боевую базу в `<имя>_before_<дата>` (она сохраняется) и
   копию в `<имя>`, запускает только `web`; перед ним отрабатывает `migrate`, и дамп старше кода
   догоняет схему.
2. Медиа на дату дампа. Дата дампа есть в имени файла (`courses-20261005-030000.dump`). Если каталог
   медиа на сервере потерян, сначала верни текущую копию, затем файлы, удалённые после дампа:

   ```bash
   DUMP_STAMP=20261005-030000      # from the dump file name
   REMOTE=<remote>:<bucket>/courses
   rclone copy "$REMOTE/media/current" /srv/courses/media
   rclone lsf --dirs-only "$REMOTE/media/deleted" | sed 's#/$##' | awk -v s="$DUMP_STAMP" '$0 > s' \
     | while read -r d; do rclone copy "$REMOTE/media/deleted/$d" /srv/courses/media; done
   sudo chown -R 1001:1001 /srv/courses/media
   ```

   Файлы, добавленные после дампа, остаются в каталоге без ссылок из базы и не мешают.
3. `node scripts/smoke.mjs https://app.<домен>` с ноутбука.
4. Платежи после даты дампа. Заказов, созданных после дампа, в базе нет, и сверка их не найдёт. В
   кабинете ЮKassa открой платежи с даты дампа; каждому успешному платежу, у которого `metadata.order_id`
   нет в `orders`, выдай доступ командой `/grant` и запиши в `PROJECT-STATE.md`.
5. Удаления после даты дампа. `/forget`, сделанные после дампа, в восстановленной базе отменились, а их
   файлы вернулись на шаге 2. Список таких команд есть в переписке администратора с ботом в Telegram
   (она живёт вне сервера). Каждую повтори.
6. Воркер. Разбери список повторных отправок из шага 1. Кто получил рассылку или шаг прогрева после
   даты дампа, по базе уже не отличить: в копии они снова `pending`. Рассылку в `sending` переведи в
   `canceled`, если повтор хуже недоставки части получателей; шаги прогревов, которым пришёл срок,
   уйдут повторно одним сообщением, и это обычно приемлемо. Только после этого
   `docker compose -f infra/docker-compose.yml --env-file infra/.env up -d worker`.
7. Когда всё сверено: удали сохранённую базу
   (`... exec -T postgres psql -U <user> -d postgres -c 'drop database "<имя>_before_<дата>"'`).

## 9. Логи

Контейнеры пишут в `json-file` с ротацией (размер и число файлов в `docker-compose.yml`).

```bash
docker compose -f infra/docker-compose.yml logs --tail=200 -f web
docker compose -f infra/docker-compose.yml logs --tail=200 -f worker
docker compose -f infra/docker-compose.yml logs --since=1h caddy | grep -v '" 200 '
```

Правила логов:

1. Логи структурные (pino, JSON), уровень задаётся `LOG_LEVEL`.
2. В лог не попадают `initData`, токены, тела вебхуков целиком, e-mail и телефоны. Достаточно `user_id`
   и идентификатора заказа.
3. Caddy вырезает параметр `token` из логируемых URL (магические ссылки входа), см. `infra/Caddyfile`.

## 10. Мониторинг

Без зарубежных сервисов ошибок: логи содержат идентификаторы пользователей, а Sentry и подобные
размещены за границей.

Минимум:

1. Uptime Kuma (ставится одним контейнером на том же или соседнем сервере; лучше соседнем, чтобы
   падение основного сервера было видно) с мониторами:
   - HTTP `https://app.<домен>/api/health`, раз в минуту;
   - срок сертификата, предупреждение за 14 дней;
   - Push-монитор для бэкапа (раздел 8);
   - Push-монитор для воркера: воркер раз в минуту стучится по адресу из переменной окружения
     (имя и место в коде определяются на этапе M4, добавить в `.env.example` вместе с кодом).
2. Уведомления Uptime Kuma уходят в Telegram-чат владельца (отдельный служебный бот, не бот
   продукта).
3. Место на диске: `df -h /` раз в неделю глазами, или монитор в Uptime Kuma, если подключён агент.

Что ещё стоит смотреть: `getWebhookInfo` (поле `last_error_message`); число заказов `pending`, у которых
`next_check_at` старше 15 минут (должно быть около нуля, иначе сверка платежей не работает); суточный
список `payments-review` от бота (заказы `pending` старше 7 дней, `docs/04-payments-yookassa.md` §4).

## 11. Чек-лист запуска в продакшен

1. DNS на месте, сертификат выпущен, `smoke.mjs` зелёный.
2. `NODE_ENV=production`, `DEV_LOGIN` пуст, секреты сгенерированы заново (не те, что на dev).
3. Telegram webhook стоит, `getWebhookInfo` без ошибок.
4. ЮKassa: магазин боевой, не тестовый, вебхук подписан, один платёж на 1 ₽ прошёл до выдачи доступа
   и возвращён (возврат вручную в кабинете, затем `/revoke`).
5. Бэкап прошёл, копия лежит в хранилище, тренировка восстановления сделана хотя бы раз.
6. Политика конфиденциальности и оферта открываются по ссылкам из `POLICY_URL` и `OFFER_URL`.
7. Владелец продукта получил доступ к менеджеру паролей с `.env` и к панели хостинга.
