---
name: start-project
description: Use for the first message in this repository while the root has no package.json yet — «Начинаем работу над проектом», the start prompt from README, «стартуем», «поехали», «разверни проект». Bootstraps the course platform from the docs in this kit — installs the macOS toolchain itself (Homebrew check, Node, Git, Docker via OrbStack), runs git init and the first commit, asks the start questions, scaffolds Next.js + Drizzle + Postgres (Docker) + vitest + Playwright, creates the folder layout from docs/01-architecture.md, fills PROJECT-STATE.md and ends with the first screenshot. Do NOT use once the app exists (then dev-flow-lite routes tasks).
---

# Старт проекта

Цель: из пакета документов получить работающий каркас, в котором `npm run dev` открывает первый
экран, база поднята, тесты и Playwright запускаются, а состояние записано. Код приложения
(экраны, API) здесь не пишется, кроме заглушки главного экрана.

Владелец ничего не ставит заранее: окружение, `git init` и первый коммит делаешь ты. Руками его
просят только о том, чего без него не сделать, и каждый раз одной командой или одним действием.

## 1. Прочитать (ровно это, не больше)

1. `docs/01-architecture.md` — целиком.
2. `docs/08-roadmap.md` — строка M0.
3. `PROJECT-STATE.md` — открытые вопросы.
4. `design/README.md` и список файлов в `design/screens/`.

Остальные документы читаются на своих этапах.

## 2. Поставить окружение (macOS) и сделать репозиторий

Проверяй и ставь сам, по одному инструменту, после каждого шага читай вывод.

```bash
xcode-select -p || xcode-select --install   # Command Line Tools; диалог macOS подтверждает владелец
brew --version
```

Homebrew нет → это единственное место, где нужен владелец: установщик спрашивает пароль Mac. Дай ему
одну команду с https://brew.sh (актуальную строку возьми с сайта, не по памяти) и жди «готово».
После установки на Apple Silicon нужен `eval "$(/opt/homebrew/bin/brew shellenv)"` в текущей
оболочке и в `~/.zprofile`; проверь `brew --version` ещё раз.

```bash
brew install node git            # Node 22 или новее; node -v, npm -v
brew install --cask orbstack     # Docker без Docker Desktop; пароль не нужен
open -a OrbStack                 # первый запуск спросит разрешения в окне, это делает владелец
docker version                   # повторяй с паузой 10 с, пока не ответит сервер
```

Docker Desktop уже стоит → OrbStack не ставь, достаточно `docker version`.

Репозиторий:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null || git init -b main
git add . && git commit -m "chore: starter kit"   # первый коммит до любых правок
```

Имя и почта для git не заданы → спроси у владельца и выставь `git config user.name/user.email`
в этом репозитории.

## 3. Задать вопросы одним сообщением

Собери вопросы Q1–Q9 из `PROJECT-STATE.md` в одно сообщение. Отсутствие ответа не блокирует M0:
токен бота и домен нужны начиная с M2/M4. Ответы запиши в `PROJECT-STATE.md` (столбец «Статус»),
неотвеченные оставь открытыми.

Отдельно спроси название проекта (английский slug для `package.json` и имени контейнеров) и
имя домена, если уже есть. Макеты в `design/screens/` пустые → скажи, что они понадобятся на этапе
M1, и продолжай.

## 4. Создать приложение

Перед каждой библиотекой сверься с актуальной документацией (context7, если подключён, иначе
официальный сайт через WebFetch): версии и флаги `create-next-app`, Drizzle, grammY, pg-boss,
`@tma.js/sdk-react` (имя пакета Telegram SDK менялось, проверь текущее) меняются.

`create-next-app` отказывается работать в непустой папке, а здесь уже лежат `README.md`, `docs/`,
`infra/`, `content/`, `scripts/`, `PROJECT-STATE.md`. Поэтому каркас создаётся во временной папке и
переносится сюда, не затирая файлы пакета:

```bash
SCAFFOLD=$(mktemp -d)
npx create-next-app@latest "$SCAFFOLD/app" --typescript --tailwind --eslint --app --src-dir \
  --import-alias "@/*" --use-npm --yes --disable-git --skip-install
cp -Rn "$SCAFFOLD/app/." ./        # -n: существующие файлы пакета не перезаписываются
npm install                        # временную папку macOS очистит сам
npm i drizzle-orm postgres grammy pg-boss jose zod pino @tma.js/sdk-react
npm i -D drizzle-kit esbuild vitest @vitest/coverage-v8 @playwright/test tsx dotenv-cli
npx playwright install chromium
```

`cp -n` оставляет наши `README.md`, `.gitignore`, `CLAUDE.md` на месте (`rsync` в этом проекте под
запретом в `.claude/settings.json`, поэтому именно `cp`); если флаги
`create-next-app` поменялись (проверь `npx create-next-app@latest --help`), подставь текущие.
Запасной путь без генератора: `npm i next react react-dom` и руками `src/app/layout.tsx`,
`src/app/page.tsx`, `next.config.ts`, `tsconfig.json`, `postcss.config.mjs` по документации Next.js.

Папки по `docs/01-architecture.md` §6: `src/lib/{auth,video,payments,funnels,content,telegram}`,
`src/bot`, `src/worker`, `src/db`, `tests`, `content/funnels`, `design/visual-check`.
В пустых папках `.gitkeep`.

`tsconfig.json`: `"strict": true`. `package.json` scripts:

```json
"dev": "next dev",
"build": "next build && cp -R .next/static .next/standalone/.next/ && cp -R public .next/standalone/",
"start": "dotenv -e .env.local -- node .next/standalone/server.js",
"typecheck": "tsc --noEmit",
"test": "vitest run",
"db:generate": "dotenv -e .env.local -- drizzle-kit generate",
"db:migrate": "dotenv -e .env.local -- tsx src/db/migrate.ts",
"content:import": "dotenv -e .env.local -- tsx scripts/import-content.ts",
"worker": "dotenv -e .env.local -- tsx src/worker/index.ts",
"build:server": "esbuild worker/index=src/worker/index.ts db/migrate=src/db/migrate.ts scripts/import-content=scripts/import-content.ts scripts/admin=scripts/admin.ts --bundle --platform=node --format=esm --target=node22 --packages=external --outdir=dist"
```

`build:server` собирает четыре входа в `dist/worker/index.js`, `dist/db/migrate.js`,
`dist/scripts/import-content.js`, `dist/scripts/admin.js`: ровно эти пути зовут `infra/docker-compose.yml`
и `docs/12-operations.md`. Имена выходов заданы явно
(`имя=вход`), потому что с общим `--outbase` esbuild положил бы их в `dist/src/...`. esbuild разворачивает
алиас `@/*` из `tsconfig.json` сам; `tsc` этого не делает, поэтому он здесь не годится.
`--packages=external` оставляет зависимости в `node_modules`: образ ставит production-зависимости целиком
(`infra/Dockerfile`), а не только то, что нашёл трейсинг Next.js. В `package.json` нужен
`"type": "module"`, иначе `.js` в `dist/` не запустится как ESM.

Команды базы, импорта и воркера обёрнуты в `dotenv -e .env.local --`: `.env.local` читает только Next,
а `tsx` и `drizzle-kit` сами его не подхватывают. `start` обёрнут так же: standalone-сервер `.env` не
читает, а `build` докладывает в `.next/standalone/` статику и `public/`, которые Next туда не копирует,
иначе локальная прод-сборка отдаёт 404 на CSS и картинки.

Major-версия Node локально (`node -v`) и в `infra/Dockerfile` (`FROM node:22-…`) должна совпадать:
`brew install node` ставит текущую версию. Расходятся → поменяй `FROM` на свою major и запиши её в
`package.json` → `engines.node`.

`drizzle.config.ts`: `schema: "./src/db/schema.ts"`, `out: "./drizzle"`, `dialect: "postgresql"`.
Папка `drizzle/` с SQL-миграциями коммитится: Dockerfile копирует её в образ, `migrate.ts` читает
её же (`migrationsFolder: "./drizzle"`).

`next.config.ts`: `output: "standalone"`.

Два служебных сигнала, которых ждёт инфраструктура (`docs/01-architecture.md` §9), создаются уже
сейчас: роут `GET /api/health` (`SELECT 1` к базе → 200, иначе 503) и в `src/worker/index.ts`
запись текущего времени в `/tmp/worker-heartbeat` раз в 30 секунд. Все четыре входа `build:server`
существуют с первого дня: `src/db/migrate.ts` (настоящий, он нужен уже в §5), заглушки
`scripts/import-content.ts` («import: not implemented until M3») и `scripts/admin.ts`
(«admin: not implemented until M4»), обе выходят с кодом 1;
esbuild падает на отсутствующем входе, и `npm run build:server` должен быть зелёным с M0.
Пакеты, которые импортируют воркер, `migrate.ts` и импортёр (`pg-boss`, `postgres`, `drizzle-orm`,
`js-yaml`, `gray-matter` и т. п.), живут в `dependencies`, не в `devDependencies`: образ ставит
`npm ci --omit=dev`, и `infra/check-runtime.mjs` в сборке образа проверяет, что каждый bare-импорт
четырёх бандлов есть в `node_modules`.

## 5. База локально

`infra/docker-compose.dev.yml` уже лежит в пакете: Postgres 16 на `localhost:5432`.

```bash
docker compose -f infra/docker-compose.dev.yml up -d
until docker compose -f infra/docker-compose.dev.yml exec -T postgres pg_isready -q; do sleep 1; done
cp infra/.env.example .env.local
```

Значения в `.env.local` (`DATABASE_URL`, `SESSION_SECRET` через `openssl rand -hex 32`, `DEV_LOGIN=1`,
`MEDIA_ROOT=./data/media`) вносит владелец сам: `.claude/settings.json` запрещает Claude читать и
править файлы `.env*` в корне и `infra/.env`. Это правило инструмента, а не изоляция: скрипт, который
Claude напишет и запустит, файл прочитать сможет, поэтому в коде секреты берутся только из `process.env`
и никогда не печатаются и не пишутся в логи. Назови владельцу переменные и дождись «готово».

`src/db/client.ts` (пул Drizzle на `postgres.js`; второй пул, `pg` для pg-boss, появится в воркере,
размеры обоих — `docs/06-bot-and-funnels.md` §6), `src/db/schema.ts` с одной таблицей `users` по `docs/02-data-model.md`
(остальные таблицы — этап M2), `drizzle.config.ts`, `src/db/migrate.ts`. Прогнать
`npm run db:generate && npm run db:migrate`, убедиться, что таблица появилась:
`docker compose -f infra/docker-compose.dev.yml exec -T postgres psql -U postgres -c '\dt'`.

## 6. Заглушка и первый скриншот

`src/app/page.tsx`: один экран с названием проекта и текстом «Этап M0». Токены цвета и шрифта
из `design/README.md`, если владелец их заполнил; иначе нейтральные.

```bash
npm run dev > /tmp/courses-dev.log 2>&1 &
node scripts/visual-check.mjs --only home --no-auth
```

Лог пишется в `/tmp`, а не в `.next/`: до первого запуска папки `.next/` нет, и оболочка упала бы на
открытии файла, не запустив сервер.

Скрипт ждёт `GET /api/health` до 60 секунд, так что гонка с запуском сервера исключена. `--no-auth`
нужен, потому что ручки `/api/dev/login` на M0 ещё нет (она появляется на M2 вместе с входом);
главный экран и так открыт без сессии. Открой полученный PNG (Read) и убедись, что страница
отрендерилась, шрифт загрузился, нет горизонтальной прокрутки. Это первый проход `visual-fidelity-loop`; дальше он применяется к каждому
экрану.

## 7. Проверки и `.gitignore`

```bash
npm run typecheck && npm test   # тестов ещё нет: добавь один smoke-тест на schema import
```

`.gitignore` уже лежит в пакете (`.env`, `.env.*` кроме `infra/.env.example`, `node_modules`, `.next`,
`dist`, `/data`); сверь, что генератор его не заменил. `design/visual-check/*.png` не игнорируется: это
свидетельство проверки экранов.

## 8. Записать состояние и закончить

- `PROJECT-STATE.md`: этап M0 закрыт, строка в журнал с датой, ответы на вопросы, допущения не
  трогать.
- `CLAUDE.md`: раздел «Команды» сверить с реальным `package.json`, лишнее убрать.
- Коммит `chore: scaffold app (M0)` (первый коммит `chore: starter kit` уже сделан в §2).
- В ответе: что создано, какие вопросы остались открытыми, и предложение начать M1 с перечнем
  экранов из `design/screens/`.

## Что не делать на старте

- Не писать экраны, API, бота, оплату: это этапы M1–M6 со своими документами.
- Не ставить Redis, Prisma, NextAuth, tRPC: архитектура их не содержит.
- Не создавать аккаунты во внешних сервисах от имени владельца.
