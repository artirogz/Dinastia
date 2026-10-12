# 02 — Модель данных

Источник правды по схеме — `src/db/schema.ts` (Drizzle). Этот документ описывает, что в нём должно
быть и какие свойства данных нельзя нарушать. SQL ниже — черновик для сверки: миграции генерирует
`drizzle-kit generate` из `schema.ts`, руками их не пишем. Перед кодом против Drizzle Claude сверяется
с актуальной документацией (синтаксис `pgTable`, индексов и `check` менялся между версиями).

## 1. Общие правила

- Первичные ключи: `serial` для справочных таблиц, `uuid` для `orders` (id идёт в deep-link бота и
  в ключ идемпотентности ЮKassa).
- Время только `timestamptz`, хранится в UTC, показывается в часовом поясе пользователя.
- Деньги только целыми в минимальных единицах: `amount_minor` (копейки) и `currency`. Никаких
  `numeric` и `float` для сумм.
- Статусы и роли — `text` с `check`, не `pgEnum`: добавить значение проще, чем мигрировать enum.
- Внешние ключи на пользовательские данные (`progress`, `comments`, `orders`, `entitlements`)
  с `ON DELETE RESTRICT`. Удаление курса или урока, за которым стоит чужая история, должно
  отказывать вслух, а не молча уносить её каскадом. Каскад только для строк-приложений
  (материалы урока, лайки, шаги цепочки).
- pg-boss хранит свои таблицы в отдельной схеме `pgboss` и управляет ими сам. В `drizzle.config.ts`
  ставится `schemaFilter: ["public"]`, чтобы drizzle-kit не пытался их «исправить». Пользователю
  базы приложения нужно право `CREATE` на базу, чтобы pg-boss создал свою схему при первом запуске.
- Сессий в базе нет: сессия — подписанный JWT в cookie (`03-auth-and-security.md` §2).

## 2. Таблицы

Пользователи и вход:

| Таблица | Назначение | Ключевые ограничения |
|---|---|---|
| `users` | человек, написавший боту или открывший приложение | `tg_id` unique not null; `role in ('user','admin')`; `consent_at` null до согласия; `marketing_consent_at` / `marketing_opt_out_at` — согласие на рекламу и его отзыв отдельно от основного; `anonymized_at` и `deleted_at` null у живого |
| `init_data_uses` | заявка на подпись `initData`, одноразовость | pk `hash`; `use_count`; индекс по `auth_date` для чистки |
| `magic_links` | одноразовые ссылки входа из браузера | pk `token_hash` (sha256 токена, сам токен не хранится); `expires_at`, `used_at` |

Контент:

| Таблица | Назначение | Ключевые ограничения |
|---|---|---|
| `courses` | курс | `slug` unique; `price_minor ≥ 0`; `access_days` null = бессрочно; `status draft/published` |
| `modules` | раздел курса | unique `(course_id, slug)`; unique `(id, course_id)` для составного ключа урока |
| `lessons` | урок | составной FK `(module_id, course_id)` → `modules(id, course_id)`: урок не может указывать на раздел чужого курса; `video_provider in ('kinescope','hls')`; `status draft/published` |
| `lesson_materials` | файлы к уроку | `file_key` — неизменяемый ключ под `MEDIA_ROOT`, не URL (контракт ниже); unique `(lesson_id, file_key)` |
| `assignments` | задание к уроку | не более одного на урок (unique `lesson_id`) |
| `assignment_submissions` | ответ пользователя | unique `(assignment_id, user_id)`: повторная отправка обновляет строку |
| `progress` | позиция и завершение | pk `(user_id, lesson_id)` |

Доступ и деньги:

| Таблица | Назначение | Ключевые ограничения |
|---|---|---|
| `entitlements` | единственный источник доступа к курсу | `source in ('purchase','manual','promo')`; `granted_by` null для покупки; partial unique по `order_id`: один заказ — не более одной выдачи |
| `orders` | заказ и платёж ЮKassa | `payment_id` unique; `status in ('pending','succeeded','canceled')`; partial unique `(user_id, course_id) where status='pending'` |
| `promo_codes` | промокоды | `lower(code)` unique; `kind in ('percent','amount','free_access')` |

Бот:

| Таблица | Назначение | Ключевые ограничения |
|---|---|---|
| `funnels`, `funnel_steps` | цепочки прогрева из `content/funnels`; `funnels.course_id` — курс, который цепочка продаёт | unique `(funnel_id, position)` |
| `funnel_enrollments` | кто в какой цепочке и на каком шаге | unique `(funnel_id, user_id)`; `stop_reason` обязателен, если `status='stopped'` |
| `broadcasts`, `broadcast_recipients` | рассылки и статус доставки каждому | pk `(broadcast_id, user_id)`; `status`, `error`, `retry_after` |
| `admin_actions` | след админских действий | пишется на `/grant`, `/revoke`, `/forget`, `/broadcast` |

Обсуждение:

| Таблица | Назначение | Ключевые ограничения |
|---|---|---|
| `comments` | комментарии к уроку, дерево через `parent_id` | `char_length(body) between 1 and 2000`; `parent_id` ON DELETE SET NULL |
| `comment_likes` | лайки | pk `(comment_id, user_id)` |
| `comment_reports` | жалобы | unique `(comment_id, user_id)`: один человек — одна жалоба на комментарий |

## 3. Инварианты данных

1. Доступ к курсу есть тогда и только тогда, когда есть строка `entitlements` с
   `starts_at ≤ now() < coalesce(ends_at, 'infinity')`, либо `users.role='admin'`. Других флагов
   «куплено» нигде нет. Отзыв доступа — это `ends_at = now()` и запись в `admin_actions`, строка не удаляется.
2. Строка `entitlements` с `source='purchase'` появляется только из `handleOrderPaid()` и несёт
   `order_id`. Partial unique по `order_id` страхует от двойной выдачи, даже если атомарный переход
   статуса когда-нибудь сломают.
3. `orders.status` переходит только `pending → succeeded` и `pending → canceled`. Обратных переходов
   нет. Возврат денег не меняет статус заказа: доступ отзывается через `entitlements`, а в заказе
   ставится `refunded_at`.
4. `orders.payment_id` уникален и заполняется после ответа ЮKassa. До этого заказ существует без него
   (`payment_id is null`), unique это допускает.
5. Контактные данные для чека (`receipt_contact`) живут только в `orders`, в `users` их нет.
6. Пользователю показываются только уроки со `status='published'`; админ видит черновики.
7. `progress.completed_at` ставится один раз и не сбрасывается: пересмотр урока двигает
   `position_sec`, но не «разпроходит» урок.
8. Импорт контента никогда не удаляет уроки и курсы: исчезнувший из файлов урок получает
   `status='draft'`, потому что за ним стоят `progress` и `comments`.
9. `/forget` обезличивает `users` (имя, username, фото → null, `anonymized_at`), удаляет
   комментарии и не трогает `orders`. Оставлять ли `tg_id` после этого — вопрос к юристу владельца;
   если нет, схема допускает замену на отрицательный суррогат `-id` (уникальность сохраняется).

## 4. Черновик DDL

```sql
create table users (
  id              serial primary key,
  tg_id           bigint not null unique,
  first_name      text,
  last_name       text,
  username        text,
  photo_url       text,
  language_code   text,
  role            text not null default 'user' check (role in ('user','admin')),
  consent_at      timestamptz,
  consent_version text,                    -- which policy text the user accepted
  marketing_consent_at timestamptz,        -- separate consent for promotional messages (06 §2)
  marketing_opt_out_at timestamptz,        -- /stop; broadcasts skip the user while set
  bot_blocked_at  timestamptz,             -- set on Telegram 403, cleared on next /start
  created_at      timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  anonymized_at   timestamptz,             -- /forget: name, username, photo wiped
  deleted_at      timestamptz              -- account closed, row kept for orders integrity
);

create table init_data_uses (
  hash         text primary key,
  tg_id        bigint not null,
  auth_date    timestamptz not null,
  use_count    integer not null default 1,
  session_jti  text not null,                  -- session issued on first use; re-issued on repeat within 60 s (03 §1)
  used_at      timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);
create index init_data_uses_auth_date_idx on init_data_uses (auth_date);

create table magic_links (
  token_hash text primary key,
  user_id    integer not null references users(id) on delete cascade,
  expires_at timestamptz not null,
  used_at    timestamptz,
  created_at timestamptz not null default now()
);

create table courses (
  id           serial primary key,
  slug         text not null unique,
  title        text not null,
  subtitle     text,
  description  text,
  cover_key    text,
  price_minor  integer not null check (price_minor >= 0),
  currency     char(3) not null default 'RUB',
  access_days  integer check (access_days > 0),   -- null = lifetime access (open question Q7)
  unlock_mode  text not null default 'all' check (unlock_mode in ('all','sequential')), -- Q8
  status       text not null default 'draft' check (status in ('draft','published')),
  sort         smallint not null default 0,
  content_hash text,
  updated_at   timestamptz not null default now()
);

create table modules (
  id        serial primary key,
  course_id integer not null references courses(id) on delete restrict,
  slug      text not null,
  title     text not null,
  sort      smallint not null default 0,
  unique (course_id, slug),
  unique (id, course_id)
);

create table lessons (
  id             serial primary key,
  course_id      integer not null,
  module_id      integer not null,
  slug           text not null,
  title          text not null,
  video_provider text not null check (video_provider in ('kinescope','hls')),
  video_ref      text not null,
  duration_sec   integer check (duration_sec > 0),
  body_md        text not null default '',       -- lesson notes (konspekt), rendered on read
  status         text not null default 'draft' check (status in ('draft','published')),
  sort           smallint not null default 0,
  published_at   timestamptz,                    -- last move to published, not a visibility flag
  content_hash   text,
  foreign key (module_id, course_id) references modules(id, course_id) on delete restrict,
  unique (course_id, slug)
);
create index lessons_module_sort_idx on lessons (module_id, sort);

create table lesson_materials (
  id         serial primary key,
  lesson_id  integer not null references lessons(id) on delete cascade,
  file_key   text not null,                      -- immutable key under MEDIA_ROOT, never a URL (see file_key contract)
  title      text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  mime       text not null,
  sort       smallint not null default 0,
  unique (lesson_id, file_key)
);

create table assignments (
  id              serial primary key,
  lesson_id       integer not null unique references lessons(id) on delete cascade,
  prompt_md       text not null,
  submission_type text not null default 'text' check (submission_type in ('text','file','text_or_file'))
);

create table assignment_submissions (
  id            serial primary key,
  assignment_id integer not null references assignments(id) on delete restrict,
  user_id       integer not null references users(id) on delete restrict,
  body          text,
  file_key      text,
  status        text not null default 'submitted' check (status in ('submitted','reviewed')),
  feedback      text,
  reviewed_by   integer references users(id) on delete set null,
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (body is not null or file_key is not null),
  unique (assignment_id, user_id)
);

create table progress (
  user_id      integer not null references users(id) on delete restrict,
  lesson_id    integer not null references lessons(id) on delete restrict,
  position_sec integer not null default 0 check (position_sec >= 0),
  completed_at timestamptz,
  updated_at   timestamptz not null default now(),
  primary key (user_id, lesson_id)
);
create index progress_user_completed_idx on progress (user_id, completed_at);

create table promo_codes (
  id          serial primary key,
  code        text not null,
  course_id   integer references courses(id) on delete restrict,  -- null = any course
  kind        text not null check (kind in ('percent','amount','free_access')),
  value       integer not null default 0 check (value >= 0),       -- percent 1..100 or minor units
  max_uses    integer check (max_uses > 0),
  valid_from  timestamptz,
  valid_until timestamptz,
  created_at  timestamptz not null default now()
);
create unique index promo_codes_code_uq on promo_codes (lower(code));

create table orders (
  id              uuid primary key default gen_random_uuid(),     -- also the payment idempotence key
  user_id         integer not null references users(id) on delete restrict,
  course_id       integer not null references courses(id) on delete restrict,
  promo_code_id   integer references promo_codes(id) on delete restrict,
  payment_id      text unique,                                    -- null until the provider answers
  status          text not null default 'pending' check (status in ('pending','succeeded','canceled')),
  amount_minor    integer not null check (amount_minor >= 0),
  currency        char(3) not null default 'RUB',
  receipt_contact text,                                           -- email or phone for the 54-FZ receipt
  raw_payload     jsonb,                                          -- last payment object read from the API
  paid_at         timestamptz,
  refunded_at     timestamptz,                                    -- full refund made in the YooKassa dashboard
  next_check_at   timestamptz not null default now() + interval '2 minutes',  -- payments-reconcile queue, 04 section 4
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index orders_one_pending_uq on orders (user_id, course_id) where status = 'pending';
create index orders_pending_next_check_idx on orders (next_check_at) where status = 'pending';

create table entitlements (
  id         serial primary key,
  user_id    integer not null references users(id) on delete restrict,
  course_id  integer not null references courses(id) on delete restrict,
  source     text not null check (source in ('purchase','manual','promo')),
  order_id   uuid references orders(id) on delete restrict,
  granted_by integer references users(id) on delete set null,    -- admin for manual/promo, null for purchase
  starts_at  timestamptz not null default now(),
  ends_at    timestamptz,                                         -- null = no expiry; revoke = set to now()
  note       text,
  created_at timestamptz not null default now(),
  check (source <> 'purchase' or order_id is not null)
);
create unique index entitlements_order_uq on entitlements (order_id) where order_id is not null;
create index entitlements_user_course_idx on entitlements (user_id, course_id);

create table funnels (
  id           serial primary key,
  slug         text not null unique,
  title        text not null,
  course_id    integer references courses(id) on delete restrict,  -- course the funnel sells; its purchase stops the funnel
  content_hash text
);

create table funnel_steps (
  id            serial primary key,
  funnel_id     integer not null references funnels(id) on delete cascade,
  position      smallint not null,
  delay_seconds integer not null check (delay_seconds >= 0),     -- from previous step (first: from enrollment)
  text          text not null,
  media         jsonb,                                            -- {type, key|url}
  buttons       jsonb,                                            -- [{text, url|callback}]
  unique (funnel_id, position)
);

create table funnel_enrollments (
  id           serial primary key,
  funnel_id    integer not null references funnels(id) on delete restrict,
  user_id      integer not null references users(id) on delete restrict,
  status       text not null default 'active' check (status in ('active','completed','stopped')),
  stop_reason  text check (stop_reason in ('purchased','bot_blocked','manual','user_stop','forgotten')),
  current_step smallint not null default 0,
  next_run_at  timestamptz,
  started_at   timestamptz not null default now(),
  stopped_at   timestamptz,
  unique (funnel_id, user_id),
  check (status <> 'stopped' or stop_reason is not null)
);
create index funnel_enrollments_due_idx on funnel_enrollments (next_run_at) where status = 'active';

create table broadcasts (
  id          serial primary key,
  slug        text not null unique,
  created_by  integer references users(id) on delete set null,
  text        text not null,
  media       jsonb,
  buttons     jsonb,
  audience    jsonb not null,                                     -- filter snapshot, e.g. {"warmup":"family","purchased":false}
  status      text not null default 'draft' check (status in ('draft','sending','done','canceled')),
  created_at  timestamptz not null default now(),
  started_at  timestamptz,
  finished_at timestamptz
);

create table broadcast_recipients (
  broadcast_id integer not null references broadcasts(id) on delete cascade,
  user_id      integer not null references users(id) on delete restrict,
  status       text not null default 'pending' check (status in ('pending','sent','failed','blocked')),
  error        text,
  attempts     smallint not null default 0,
  retry_after  timestamptz,                                       -- from Telegram 429 retry_after
  sent_at      timestamptz,
  primary key (broadcast_id, user_id)
);
create index broadcast_recipients_pending_idx on broadcast_recipients (broadcast_id, retry_after) where status = 'pending';

create table comments (
  id         serial primary key,
  lesson_id  integer not null references lessons(id) on delete restrict,
  user_id    integer not null references users(id) on delete restrict,
  parent_id  integer references comments(id) on delete set null,
  body       text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by integer references users(id) on delete set null     -- body stays in the table for review
);
create index comments_lesson_created_idx on comments (lesson_id, created_at);
create index comments_user_created_idx on comments (user_id, created_at);  -- rate limit lookup
create index comments_parent_idx on comments (parent_id);

create table comment_likes (
  comment_id integer not null references comments(id) on delete cascade,
  user_id    integer not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);

create table comment_reports (
  id          serial primary key,
  comment_id  integer not null references comments(id) on delete cascade,
  user_id     integer not null references users(id) on delete cascade,
  reason      text,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  unique (comment_id, user_id)
);

create table admin_actions (
  id      serial primary key,
  tg_id   bigint not null,                                        -- an admin may never have opened the app
  action  text not null,                                          -- grant | revoke | forget | broadcast | ...
  target  text not null,                                          -- e.g. user:42, course:example-course
  details jsonb,
  at      timestamptz not null default now()
);
```

## 5. Что вычисляется, а не хранится

| Значение | Как считается |
|---|---|
| Прогресс курса, % | `count(progress.completed_at)` / `count(lessons where status='published')` по курсу пользователя |
| «Пройдено 7 из 12» | те же два числа |
| Следующий урок | первый опубликованный урок по `(modules.sort, lessons.sort)` без `completed_at` |
| Есть ли доступ | предикат из инварианта 1, функция `requireCourseAccess()` |
| Число комментариев и лайков | `count(*)` по `comments` (без `deleted_at`) и `comment_likes` |
| Сколько раз использован промокод | `count(orders)` со статусом `succeeded` и этим `promo_code_id`, включая бесплатные заказы `free_access`; `entitlements` с `source='promo'` не добавляются, у каждой из них есть такой заказ (`04-payments-yookassa.md` §5, «Промокоды») |
| Размер аудитории рассылки | запрос по `audience` на момент запуска; результат фиксируется строками `broadcast_recipients` |
| Получено, возвращено, выручка | получено: `sum(amount_minor)` по `orders` со статусом `succeeded`; возвращено: `sum(amount_minor)` по тем же заказам с `refunded_at is not null`; выручка = получено минус возвращено (частичные возвраты в базе не отражаются, `04-payments-yookassa.md` §6) |
| Число покупателей | `count(distinct user_id)` по `orders` со статусом `succeeded`, `amount_minor > 0` и `refunded_at is null` |

Счётчики-поля, которые надо обновлять в двух местах, не заводим: они расходятся при первой же гонке.

## 6. Импорт контента: файл → таблица

`npm run content:import` идёт по `content/courses/<slug>/` и работает идемпотентно по `slug`
(формат файлов — `content/README.md`).

| Источник | Куда |
|---|---|
| `course.yaml`: `slug`, `title`, `subtitle`, `price_minor`, `access_days`, `unlock_mode`, `status` | `courses` |
| `course.yaml`: `modules[]` (`slug`, `title`, порядок в списке) | `modules`, `sort` = индекс в списке |
| `lessons/NN-slug.md`, frontmatter: `title`, `module`, `video_provider`, `video_ref` | `lessons` (`module` — slug раздела из `course.yaml`) |
| `NN` в имени файла урока | `lessons.sort` |
| frontmatter: `duration_sec` | `lessons.duration_sec`; перекрывается значением `VideoProvider.describe()`, если провайдер его отдал |
| тело файла урока | `lessons.body_md` |
| `course.yaml`: `description`, `cover` | `courses.description`; обложка копируется в `MEDIA_ROOT` под ключом `courses/<slug>/<hash16>-<file>` → `courses.cover_key`; файла нет → предупреждение, `cover_key` null |
| frontmatter: `materials[]` | `lesson_materials`; файл копируется в `MEDIA_ROOT` под ключом `courses/<slug>/<hash16>-<file>` (контракт `file_key`), размер и mime берутся с диска |
| frontmatter: `assignment` | `assignments` (`prompt_md`, `submission_type`) |
| `content/funnels/<slug>.yaml` | `funnels` и `funnel_steps` (формат — `06-bot-and-funnels.md`) |

Правила импорта:

1. Строка ищется по `slug` (для урока — по паре `course_id, slug`). Нет — создаётся, есть — обновляется.
2. `content_hash` (sha256 нормализованного файла) совпал — строка не трогается. Второй прогон на тех
   же файлах не меняет ничего. Хеш считается по markdown и yaml; вложения (материалы, обложка, медиа
   прогревов) сравниваются отдельно по sha256 содержимого: изменился файл под тем же именем → новый
   `file_key`, строка обновляется. Уроки, у которых `describe()` в прошлый раз вернул `ready=false`,
   перечитываются у провайдера при каждом импорте независимо от хеша.
3. Урок со статусом `draft` в файле остаётся `draft` в базе; первый переход в `published` ставит
   `published_at`.
4. Урок, которого больше нет в файлах, не удаляется: получает `status='draft'`, импорт печатает
   предупреждение.
5. Модуль и урок нельзя «перенести» в другой курс правкой файла: составной ключ это запрещает,
   импорт падает с понятной ошибкой.
6. Импорт не трогает `progress`, `comments`, `entitlements`, `orders`.

**Контракт `file_key`** (материалы, обложки, медиа прогревов, файлы ответов на задания): ключ неизменяемый,
`<область>/<первые 16 hex sha256 содержимого>-<имя файла>`, например `courses/example-course/3f9a…c1-plan.pdf`.
Новый файл всегда получает новый ключ; файл по старому ключу удаляется только когда на него не осталось
ни одной строки (это делает `cleanup`). Так дамп базы на любую дату ссылается на файлы, которые ещё
лежат в бэкапе медиа (`09-infra-and-deploy.md` §8), а удаление по `/forget` удаляет и файлы ответов
с диска вместе со строками.
