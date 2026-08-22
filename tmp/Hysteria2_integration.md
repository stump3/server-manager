# Интеграция Hysteria 2 в Remnawave (cipherwaypanel)

> **Для кого:** инженеры, впервые работающие с кодовой базой Remnawave / cipherwaypanel.  
> **Цель:** заменить текущий ручной инжект ключей Hysteria 2 в подписку на полноценную нативную интеграцию с управлением через панель.

---

## 1. Обзор системы

### Что такое Remnawave

Remnawave — это панель управления VPN-сервером на базе Xray-core. Состоит из четырёх репозиториев, объединённых в монорепо **cipherwaypanel**:

| Каталог | Роль | Технологии |
|---|---|---|
| `remnawave-backend` | API-сервер, бизнес-логика, работа с БД | NestJS, Prisma, PostgreSQL |
| `remnawave-node` | Агент на VPN-ноде, управляет процессами | NestJS, supervisord |
| `remnawave-frontend` | Веб-интерфейс панели | React, Vite |
| `remnawave-panel` | Документация | Docusaurus |

### Как сейчас работает Hysteria 2

На данный момент Hysteria 2 реализован через **инжект ключей напрямую в подписку** — то есть URI вида `hy2://...` добавляется в ссылку подписки вручную, без связи с пользователями панели. Это означает:

- нет автоматической синхронизации пользователей с нодой;
- нет управления через UI;
- при добавлении/удалении пользователя Hysteria 2 не обновляется.

### Целевое состояние

Hysteria 2 становится полноправным протоколом в панели:

1. Нода запускает процесс `hysteria2` через supervisord (рядом с `xray`).
2. Backend хранит конфигурацию Hysteria 2 inbound в БД и синхронизирует пользователей на ноду.
3. Генератор подписок отдаёт нативный `hy2://` URI — клиент (v2rayN, NekoBox, Hiddify) видит Hysteria 2 как отдельный сервер с правильным типом.
4. UI панели позволяет добавлять/редактировать Hysteria 2 inbound для ноды.

---

## 2. Архитектура решения

```
┌─────────────────────────────────────────────────────┐
│                   remnawave-backend                  │
│                                                     │
│  Hysteria2Inbound (Prisma)  ←→  Hysteria2 API       │
│  Sync Handler               ←→  User events         │
│  Subscription Generator     →   hy2:// URI          │
└────────────────────┬────────────────────────────────┘
                     │ HTTP (mTLS)
                     ▼
┌─────────────────────────────────────────────────────┐
│                   remnawave-node                     │
│                                                     │
│  Hysteria2Service  →  генерация config.yaml         │
│  supervisord       →  запуск процесса hysteria2     │
│  Hysteria2Controller ← эндпоинты sync/start/stop   │
└─────────────────────────────────────────────────────┘
```

---

## 3. Этап 1 — Нода: запуск Hysteria 2 как процесса

### 3.1 Где находится код ноды

```
remnawave-node/
└── src/
    └── modules/
        ├── xray-core/          ← эталон для реализации (Xray уже работает так)
        │   ├── xray.service.ts
        │   ├── xray.controller.ts
        │   └── xray.module.ts
        └── hysteria2/          ← здесь сейчас заглушка, нужно заменить
            ├── hysteria2.service.ts
            └── hysteria2.module.ts
```

> **Ориентир:** файл `xray.service.ts` — смотреть туда при реализации, логика запуска `hysteria2` аналогична.

### 3.2 Как сейчас запускается Xray (эталон)

Xray запускается через **supervisord** — менеджер процессов внутри Docker-контейнера ноды. Конфигурация supervisord находится в:

```
remnawave-node/supervisord.conf
```

Xray-сервис в NestJS через `XrayService`:
1. Генерирует JSON-конфиг Xray из данных, полученных от backend.
2. Записывает конфиг в файл (путь из переменной окружения).
3. Через supervisord API перезапускает процесс `xray`.

### 3.3 Что нужно сделать

#### a) Добавить `hysteria2` в supervisord

В файл `remnawave-node/supervisord.conf` добавить секцию:

```ini
[program:hysteria2]
command=/usr/local/bin/hysteria server --config /etc/hysteria2/config.yaml
autostart=false
autorestart=true
stdout_logfile=/var/log/hysteria2.log
stderr_logfile=/var/log/hysteria2.err.log
```

> `autostart=false` — процесс запускается только командой от панели, не при старте контейнера.

#### b) Добавить бинарь в Dockerfile

В файл `remnawave-node/Dockerfile` добавить установку `hysteria2`:

```dockerfile
# Пример — версию уточнить на https://github.com/apernet/hysteria/releases
ARG HYSTERIA2_VERSION=2.6.0
RUN curl -Lo /usr/local/bin/hysteria \
    https://github.com/apernet/hysteria/releases/download/app/v${HYSTERIA2_VERSION}/hysteria-linux-amd64 \
  && chmod +x /usr/local/bin/hysteria
```

#### c) Реализовать `Hysteria2Service`

Заменить заглушку в `remnawave-node/src/modules/hysteria2/hysteria2.service.ts`:

```typescript
@Injectable()
export class Hysteria2Service {
    // Генерирует /etc/hysteria2/config.yaml из списка пользователей
    async writeConfig(users: Hysteria2User[], inbound: Hysteria2InboundConfig): Promise<void>

    // Запускает процесс через supervisord API
    async start(): Promise<void>

    // Останавливает процесс
    async stop(): Promise<void>

    // Обновляет конфиг и перезапускает процесс
    async syncUsers(users: Hysteria2User[]): Promise<void>
}
```

Формат генерируемого `config.yaml`:

```yaml
listen: :8443
tls:
  cert: /etc/hysteria2/cert.pem
  key: /etc/hysteria2/key.pem
auth:
  type: password
  password: ""   # не используется — используем userPassword ниже
obfs:
  type: salamander
  salamander:
    password: ""
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/

# Список пользователей генерируется динамически
users:
  - name: "uuid-пользователя"
    password: "vless-uuid-пользователя"
```

> Пароль пользователя в Hysteria 2 = `vlessUuid` из БД панели (так же, как сейчас делает Xray в upstream).

#### d) Добавить контроллер

Создать `remnawave-node/src/modules/hysteria2/hysteria2.controller.ts` с эндпоинтами:

| Метод | Путь | Действие |
|---|---|---|
| `POST` | `/hysteria2/start` | Запустить процесс |
| `POST` | `/hysteria2/stop` | Остановить процесс |
| `POST` | `/hysteria2/sync` | Обновить пользователей и перезапустить |
| `GET` | `/hysteria2/status` | Статус процесса |

#### e) Новые переменные окружения ноды

В `.env.sample` ноды (`remnawave-node/.env.sample`) добавить:

```env
HYSTERIA2_ENABLED=false
HYSTERIA2_PORT=8443
HYSTERIA2_CONFIG_PATH=/etc/hysteria2/config.yaml
HYSTERIA2_CERT_PATH=/etc/hysteria2/cert.pem
HYSTERIA2_KEY_PATH=/etc/hysteria2/key.pem
```

В схему конфига `remnawave-node/src/common/config/app-config/config.schema.ts` добавить соответствующие поля (поле `HYSTERIA2_ENABLED` уже есть, нужно добавить остальные).

### 3.4 Команды для разработки ноды

```bash
# Перейти в каталог ноды
cd remnawave-node

# Установить зависимости (требуется Linux / WSL2 — модуль nftables не собирается на Windows)
npm ci

# Собрать TypeScript
npm run build

# Собрать Docker-образ
docker build -t cipherway-node:dev .

# Запустить с тестовыми переменными
docker run --rm -it \
  -e NODE_PORT=2222 \
  -e SECRET_KEY='...' \
  -e HYSTERIA2_ENABLED=true \
  -e HYSTERIA2_PORT=8443 \
  -p 2222:2222 -p 8443:8443/udp \
  cipherway-node:dev
```

> **Важно:** порт Hysteria 2 должен быть открыт по **UDP**, не TCP.

---

## 4. Этап 2 — Backend: модель данных и API

### 4.1 Где находится код backend

```
remnawave-backend/
├── prisma/
│   └── schema.prisma           ← схема БД
├── src/
│   └── modules/
│       ├── nodes/              ← управление нодами (эталон)
│       │   └── events/
│       │       └── add-user-to-node/   ← синхронизация пользователей
│       └── subscription-template/
│           └── generators/     ← генераторы подписок
│               ├── xray-json.generator.service.ts
│               ├── singbox.generator.service.ts
│               └── clash.generator.service.ts
└── libs/
    └── contract/
        └── api/
            └── controllers/    ← контракты API (типы запросов/ответов)
```

### 4.2 Добавить модель в Prisma

Файл: `remnawave-backend/prisma/schema.prisma`

Добавить новую модель:

```prisma
model Hysteria2Inbound {
  id          String   @id @default(cuid())
  nodeId      String   @unique
  port        Int      @default(8443)
  domain      String                    // домен/IP ноды для Hysteria 2
  certPath    String                    // путь к сертификату на ноде
  keyPath     String                    // путь к ключу на ноде
  isEnabled   Boolean  @default(false)
  createdAt   DateTime @default(now())
  updatedAt   DateTime @updatedAt

  node        Node     @relation(fields: [nodeId], references: [id], onDelete: Cascade)
}
```

После добавления модели:

```bash
cd remnawave-backend

# Создать миграцию
npx prisma migrate dev --name add_hysteria2_inbound

# Применить на продакшене
npx prisma migrate deploy
```

### 4.3 Добавить API-контракт

Файл: `remnawave-backend/libs/contract/api/controllers/hysteria2.ts`

```typescript
export const hysteria2Contract = {
    createInbound: {
        method: 'POST',
        path: '/hysteria2/inbounds',
        // body: { nodeId, port, domain, certPath, keyPath }
    },
    updateInbound: {
        method: 'PATCH',
        path: '/hysteria2/inbounds/:nodeId',
    },
    deleteInbound: {
        method: 'DELETE',
        path: '/hysteria2/inbounds/:nodeId',
    },
    syncNode: {
        method: 'POST',
        path: '/hysteria2/inbounds/:nodeId/sync',
    },
};
```

Зарегистрировать в `remnawave-backend/libs/contract/api/controllers/index.ts`.

### 4.4 Реализовать sync пользователей на ноду

По аналогии с существующим файлом:
```
remnawave-backend/src/modules/nodes/events/add-user-to-node/add-user-to-node.handler.ts
```

Создать обработчик события изменения пользователя, который будет вызывать `POST /hysteria2/sync` на нужной ноде со списком всех активных пользователей.

Логика:
1. Получить всех активных пользователей из БД.
2. Для каждой ноды с включённым Hysteria 2 inbound — вызвать `/hysteria2/sync` со списком `[{ name, password: vlessUuid }]`.

---

## 5. Этап 3 — Генератор подписок: нативный `hy2://` URI

### 5.1 Где находится генератор

```
remnawave-backend/src/modules/subscription-template/generators/
```

### 5.2 Формат URI

Стандартный URI Hysteria 2, который понимают все клиенты:

```
hy2://<password>@<domain>:<port>?sni=<domain>&insecure=0#<remark>
```

Пример:
```
hy2://550e8400-e29b-41d4-a716-446655440000@cdn.example.com:8443?sni=cdn.example.com&insecure=0#Germany Hysteria2
```

### 5.3 Что добавить в генератор

В файле `xray-json.generator.service.ts` уже есть обработка `hysteria`. Нужно добавить отдельный путь в **resolve-proxy**, который будет возвращать `hy2://` URI напрямую, не оборачивая в Xray-JSON.

Файл для изменения:
```
remnawave-backend/src/modules/subscription-template/resolve-proxy/resolve-proxy-config.service.ts
```

Добавить ветку:

```typescript
case 'hysteria2':
    return `hy2://${user.vlessUuid}@${host.address}:${host.port}` +
           `?sni=${host.sni}&insecure=0` +
           `#${encodeURIComponent(host.remark)}`;
```

> После этого клиенты (v2rayN, NekoBox, Hiddify) будут отображать Hysteria 2 как отдельную строку с типом `Hysteria2`, как на картинке 2 из задания.

---

## 6. Этап 4 — Frontend: UI для управления

### 6.1 Где находится код frontend

```
remnawave-frontend/src/
├── app/
│   └── router/router.tsx       ← маршруты
└── entities/
    └── dashboard/
        └── nodes/              ← компоненты нод (эталон для нового раздела)
```

### 6.2 Что добавить

Новая секция в карточке ноды — настройки Hysteria 2:

- Переключатель «включить Hysteria 2 для этой ноды»
- Поля: порт, домен, путь к сертификату, путь к ключу
- Кнопка «Синхронизировать пользователей»
- Статус процесса (работает / остановлен)

По аналогии с формами хостов:
```
remnawave-frontend/src/entities/dashboard/hosts/
```

### 6.3 Команды для разработки frontend

```bash
cd remnawave-frontend

# Установить зависимости
npm ci

# Запустить dev-сервер
npm run dev

# Собрать для продакшена
npm run build
```

---

## 7. Порядок внедрения

```
┌──────────────────────────────────────────────────────────────────┐
│  Этап 1 (нода)                                                   │
│  Dockerfile + supervisord + Hysteria2Service + Controller        │
│  Результат: нода умеет запускать hysteria2 и принимать users     │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│  Этап 2 (backend)                                                │
│  Prisma модель + миграция + API + sync handler                   │
│  Результат: панель хранит конфиги и синхронизирует пользователей │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│  Этап 3 (подписки)                                               │
│  hy2:// URI в генераторе подписок                                │
│  Результат: клиенты видят Hysteria 2 как отдельный сервер        │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│  Этап 4 (frontend)                                               │
│  UI для настройки Hysteria 2 inbound                             │
│  Результат: полное управление через веб-интерфейс                │
└──────────────────────────────────────────────────────────────────┘
```

Этапы 1 и 2 можно вести параллельно разными командами.

---

## 8. Сравнение текущего и целевого состояния

| Параметр | Сейчас (инжект) | После интеграции |
|---|---|---|
| Добавление пользователя | Вручную | Автоматически через панель |
| Синхронизация с нодой | Отсутствует | Событийная, как у VLESS |
| Формат в подписке | Инжект URI | Нативный `hy2://` |
| Отображение в клиенте | Зависит от клиента | `Hysteria2 \| Germany \| cdn.example.com:8443` |
| Управление через UI | Нет | Есть |
| Сертификаты | Вручную | Путь задаётся в UI |

---

## 9. Требования к окружению разработки

| Компонент | Требование |
|---|---|
| ОС для ноды | Linux или WSL2 (модуль `nftables-napi` не собирается на Windows) |
| Node.js | ≥ 20 (указано в `package.json` каждого подпроекта) |
| Docker | Для сборки образов ноды |
| PostgreSQL | Для backend (поднимается через `docker-compose-db-local.yml`) |

### Быстрый старт БД для backend

```bash
cd remnawave-backend

# Поднять PostgreSQL локально
docker compose -f docker-compose-db-local.yml up -d

# Применить все миграции
npx prisma migrate deploy

# Запустить backend в dev-режиме
npm run start:dev
```

---

## 10. Ссылки

- Репозиторий форка: [https://github.com/Nirbee/cipherwaypanel](https://github.com/Nirbee/cipherwaypanel)
- Документация Xray Hysteria inbound: [https://xtls.github.io/config/inbounds/hysteria.html](https://xtls.github.io/config/inbounds/hysteria.html)
- Документация Hysteria 2 server config: [https://v2.hysteria.network/docs/advanced/Full-Server-Config/](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)
- Релизы бинаря hysteria2: [https://github.com/apernet/hysteria/releases](https://github.com/apernet/hysteria/releases)
