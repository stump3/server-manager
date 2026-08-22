# Hysteria 2 — Документация по внедрению в cipherwaypanel

> **Назначение документа:** полное описание всех изменений, внесённых в кодовую базу при добавлении нативной поддержки Hysteria 2 в панель Remnawave (форк cipherwaypanel). Документ написан для инженеров, которые будут продолжать разработку, делать code review или разворачивать проект.

---

## Содержание

1. [Общая архитектура решения](#1-общая-архитектура-решения)
2. [remnawave-node — изменения](#2-remnawave-node--изменения)
3. [remnawave-backend — изменения](#3-remnawave-backend--изменения)
4. [Что не реализовано и требует доработки](#4-что-не-реализовано-и-требует-доработки)
5. [Переменные окружения](#5-переменные-окружения)
6. [Миграция БД](#6-миграция-бд)
7. [API-справочник](#7-api-справочник)

---

## 1. Общая архитектура решения

Hysteria 2 запускается как **отдельный процесс** (`hysteria server`) на той же машине, что и Xray-core, под управлением того же supervisord. Панель управляет им через HTTP API ноды — точно так же, как управляет Xray.

```
remnawave-backend
  │
  │  1. Upsert Hysteria2Inbound (порт, домен, сертификаты)
  │  2. После старта ноды → POST /node/hysteria2/sync (список пользователей)
  ▼
remnawave-node
  │
  │  3. Пишет /etc/hysteria2/config.yaml
  │  4. supervisord.startProcess('hysteria2')
  ▼
hysteria binary (процесс)
  └─ слушает :8443/udp
  └─ auth: userpass (uuid → vlessUuid)

remnawave-backend (генератор подписок)
  └─ appendHysteria2Entries() → hy2://vlessUuid@domain:port?sni=...#Remark
```

**Ключевые архитектурные решения:**

- Hysteria 2 привязан к **существующей ноде** через `nodeId` — отдельной сущности ноды нет.
- Трафик пишется в ту же ноду, что и Xray — суммарно, без разделения по протоколу.
- Пользовательский пароль в Hysteria 2 = `vlessUuid` пользователя (уже есть в БД, не нужно отдельное поле).
- `hy2://` URI добавляется в подписку **поверх** Xray-хостов, не заменяя их.

---

## 2. remnawave-node — изменения

### 2.1 `Dockerfile`

**Файл:** `remnawave-node/Dockerfile`

Добавлены:

**ARG** для версии бинаря:
```dockerfile
ARG HYSTERIA2_VERSION=2.6.1
```

**Скачивание бинаря** в build-stage рядом со скачиванием Xray:
```dockerfile
RUN apk add --no-cache curl unzip \
    && curl -L ${XRAY_CORE_INSTALL_SCRIPT} | sh -s -- ${XRAY_CORE_VERSION} ${UPSTREAM_REPO} \
    && curl -Lo /usr/local/bin/hysteria \
        "https://github.com/apernet/hysteria/releases/download/app%2Fv${HYSTERIA2_VERSION}/hysteria-linux-amd64" \
    && chmod +x /usr/local/bin/hysteria
```

**Копирование бинаря** в финальный образ рядом с xray:
```dockerfile
COPY --from=build /usr/local/bin/hysteria /usr/local/bin/hysteria
```

**Создание директории** для конфига и вспомогательных скриптов:
```dockerfile
RUN apk add --no-cache supervisor libnftnl libmnl && \
    mkdir -p /var/log/supervisor /etc/hysteria2 && \
    chmod +x /usr/local/bin/docker-entrypoint.sh && \
    ln -s /usr/local/bin/xray /usr/local/bin/rw-core && \
    echo '#!/bin/sh' > /usr/local/bin/hlogs && \
    echo 'tail -n +1 -f /var/log/supervisor/hysteria2.out.log' >> /usr/local/bin/hlogs && \
    chmod +x /usr/local/bin/hlogs && \
    echo '#!/bin/sh' > /usr/local/bin/herrors && \
    echo 'tail -n +1 -f /var/log/supervisor/hysteria2.err.log' >> /usr/local/bin/herrors && \
    chmod +x /usr/local/bin/herrors
```

> `hlogs` и `herrors` — утилиты для просмотра логов hysteria2 из контейнера, аналог уже существующих `xlogs`/`xerrors` для Xray.

**ENV defaults** в Dockerfile:
```dockerfile
ENV HYSTERIA2_ENABLED=false
ENV HYSTERIA2_PORT=8443
ENV HYSTERIA2_CONFIG_PATH=/etc/hysteria2/config.yaml
ENV HYSTERIA2_CERT_PATH=/etc/hysteria2/cert.pem
ENV HYSTERIA2_KEY_PATH=/etc/hysteria2/key.pem
ENV HYSTERIA2_MASQUERADE_URL=https://news.ycombinator.com/
ENV HYSTERIA2_OBFS_PASSWORD=
```

---

### 2.2 `supervisord.conf`

**Файл:** `remnawave-node/supervisord.conf`

Добавлена секция для процесса Hysteria 2 — полностью аналогична секции `[program:xray]`:

```ini
[program:hysteria2]
command=/usr/local/bin/hysteria server --config %(ENV_HYSTERIA2_CONFIG_PATH)s
autostart=false
autorestart=false
stderr_logfile=/var/log/supervisor/hysteria2.err.log
stdout_logfile=/var/log/supervisor/hysteria2.out.log
stdout_logfile_maxbytes=5MB
stderr_logfile_maxbytes=5MB
stdout_logfile_backups=0
stderr_logfile_backups=0
```

> `autostart=false` — процесс не стартует при запуске контейнера. Панель запускает его только после получения первого `sync` с пользователями.
>
> `autorestart=false` — не перезапускается автоматически. При изменении пользователей панель сама перезапускает процесс через supervisord API.

---

### 2.3 `config.schema.ts`

**Файл:** `remnawave-node/src/common/config/app-config/config.schema.ts`

Добавлены переменные окружения (Zod schema):

```typescript
HYSTERIA2_ENABLED: z
    .string()
    .default('false')
    .transform((val) => val === 'true'),
HYSTERIA2_PORT: z
    .string()
    .default('8443')
    .transform((port) => parseInt(port, 10)),
HYSTERIA2_MASQUERADE_URL: z.string().default('https://news.ycombinator.com/'),
HYSTERIA2_CONFIG_PATH: z.string().default('/etc/hysteria2/config.yaml'),
HYSTERIA2_CERT_PATH: z.string().default('/etc/hysteria2/cert.pem'),
HYSTERIA2_KEY_PATH: z.string().default('/etc/hysteria2/key.pem'),
HYSTERIA2_OBFS_PASSWORD: z.string().default(''),
```

---

### 2.4 Контракты (`libs/contract/`)

#### `libs/contract/api/controllers/hysteria2.ts` — новый файл

Константы имени контроллера и роутов:

```typescript
export const HYSTERIA2_CONTROLLER = 'hysteria2' as const;

export const HYSTERIA2_ROUTES = {
    START: 'start',
    STOP:  'stop',
    STATUS: 'status',
    SYNC: 'sync',
} as const;
```

#### `libs/contract/api/controllers/index.ts` — изменён

Добавлен ре-экспорт нового контроллера:
```typescript
export * from './hysteria2';
```

#### `libs/contract/api/routes.ts` — изменён

Добавлена секция `HYSTERIA2` в объект `REST_API`:

```typescript
HYSTERIA2: {
    START:  `${ROOT}/${CONTROLLERS.HYSTERIA2_CONTROLLER}/${CONTROLLERS.HYSTERIA2_ROUTES.START}`,
    STOP:   `${ROOT}/${CONTROLLERS.HYSTERIA2_CONTROLLER}/${CONTROLLERS.HYSTERIA2_ROUTES.STOP}`,
    STATUS: `${ROOT}/${CONTROLLERS.HYSTERIA2_CONTROLLER}/${CONTROLLERS.HYSTERIA2_ROUTES.STATUS}`,
    SYNC:   `${ROOT}/${CONTROLLERS.HYSTERIA2_CONTROLLER}/${CONTROLLERS.HYSTERIA2_ROUTES.SYNC}`,
},
```

#### `libs/contract/commands/hysteria2/sync.command.ts` — новый файл

Zod-схема запроса и ответа для эндпоинта `POST /node/hysteria2/sync`:

```typescript
export namespace SyncHysteria2Command {
    export const url = REST_API.HYSTERIA2.SYNC;

    export const UserSchema = z.object({
        name: z.string(),      // uuid пользователя
        password: z.string(),  // vlessUuid пользователя
    });

    export const RequestSchema = z.object({
        users: z.array(UserSchema),
    });

    export const ResponseSchema = z.object({
        response: z.object({
            isStarted: z.boolean(),
            error: z.string().nullable(),
        }),
    });
}
```

#### `libs/contract/commands/hysteria2/status.command.ts` — новый файл

Zod-схема ответа для `GET /node/hysteria2/status`:

```typescript
export namespace GetHysteria2StatusCommand {
    export const ResponseSchema = z.object({
        response: z.object({
            isRunning: z.boolean(),
            version: z.string().nullable(),
            port: z.number(),
            error: z.string().nullable(),
        }),
    });
}
```

#### `libs/contract/commands/index.ts` — изменён

Добавлен ре-экспорт:
```typescript
export * from './hysteria2';
```

---

### 2.5 `hysteria2.service.ts`

**Файл:** `remnawave-node/src/modules/hysteria2/hysteria2.service.ts`

Полная замена заглушки. Сервис реализует `OnApplicationBootstrap`.

**Что делает при старте приложения (`onApplicationBootstrap`):**
- Если `HYSTERIA2_ENABLED=false` — пишет лог и выходит.
- Проверяет наличие бинаря `/usr/local/bin/hysteria`.
- Создаёт директорию конфига если не существует.

**Публичные методы:**

`syncUsers(users)` — основной метод:
1. Генерирует YAML-конфиг и записывает в `HYSTERIA2_CONFIG_PATH`.
2. Вызывает `restartProcess()` — останавливает процесс если запущен, запускает снова.
3. Обновляет внутренний флаг `isRunning`.

`stopProcess()` — останавливает процесс через supervisord API.

`getStatus()` — возвращает состояние (`isRunning`, версию бинаря, порт).

**Приватные методы:**

`writeConfig(users)` — генерирует `config.yaml`:
```yaml
listen: :8443
tls:
  cert: /etc/hysteria2/cert.pem
  key:  /etc/hysteria2/key.pem
# obfs секция — только если HYSTERIA2_OBFS_PASSWORD не пустой
auth:
  type: userpass
  userpass:
    - name: "uuid-пользователя"
      password: "vless-uuid-пользователя"
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
bandwidth:
  up: 1 gbps
  down: 1 gbps
```

`restartProcess()` — проверяет state процесса через supervisord (state 20 = RUNNING), останавливает если запущен, затем запускает.

`getBinaryVersion()` — выполняет `hysteria version`, парсит строку для получения версии.

---

### 2.6 `hysteria2.controller.ts`

**Файл:** `remnawave-node/src/modules/hysteria2/hysteria2.controller.ts`

Новый файл. Контроллер защищён `JwtDefaultGuard` (mTLS токен панели).

| Метод | Путь | Действие |
|---|---|---|
| `POST` | `/node/hysteria2/sync` | Обновить список пользователей и перезапустить процесс |
| `GET` | `/node/hysteria2/stop` | Остановить процесс |
| `GET` | `/node/hysteria2/status` | Статус процесса и версия бинаря |

---

### 2.7 `hysteria2.module.ts`

**Файл:** `remnawave-node/src/modules/hysteria2/hysteria2.module.ts`

Полная замена заглушки. Модуль реализует `OnModuleDestroy` — при остановке приложения вызывает `stopProcess()`, чтобы корректно завершить процесс hysteria2.

```typescript
@Module({
    providers: [Hysteria2Service],
    controllers: [Hysteria2Controller],
    exports: [Hysteria2Service],
})
export class Hysteria2Module implements OnModuleDestroy {
    async onModuleDestroy() {
        await this.hysteria2Service.stopProcess();
    }
}
```

---

### 2.8 `remnawave-node.modules.ts`

**Файл:** `remnawave-node/src/modules/remnawave-node.modules.ts`

Без изменений — `Hysteria2Module` был зарегистрирован ещё в оригинальной заглушке:

```typescript
imports: [NetworkStatsModule, PluginModule, StatsModule, XrayModule, Hysteria2Module, HandlerModule],
```

---

### 2.9 Модели и DTO ноды

**Новые файлы:**

`src/modules/hysteria2/models/sync-hysteria2.response.model.ts`
```typescript
export class SyncHysteria2ResponseModel {
    public readonly isStarted: boolean;
    public readonly error: string | null;
}
```

`src/modules/hysteria2/models/get-hysteria2-status.response.model.ts`
```typescript
export class GetHysteria2StatusResponseModel {
    public readonly isRunning: boolean;
    public readonly version: string | null;
    public readonly port: number;
    public readonly error: string | null;
}
```

`src/modules/hysteria2/dtos/hysteria2.dto.ts`
```typescript
// DTO через nestjs-zod из контрактных схем
export class SyncHysteria2RequestDto extends createZodDto(SyncHysteria2Command.RequestSchema) {}
export class SyncHysteria2ResponseDto extends createZodDto(SyncHysteria2Command.ResponseSchema) {}
export class GetHysteria2StatusResponseDto extends createZodDto(GetHysteria2StatusCommand.ResponseSchema) {}
```

---

## 3. remnawave-backend — изменения

### 3.1 `prisma/schema.prisma`

**Файл:** `remnawave-backend/prisma/schema.prisma`

Добавлены:

**Back-relation в модели `Nodes`:**
```prisma
hysteria2Inbound Hysteria2Inbound?
```

**Новая модель `Hysteria2Inbound`:**
```prisma
model Hysteria2Inbound {
  id        BigInt  @id @default(autoincrement())
  nodeId    BigInt  @unique @map("node_id")
  port      Int     @default(8443) @map("port")
  domain    String  @map("domain")
  sni       String  @map("sni")
  certPath  String  @map("cert_path")
  keyPath   String  @map("key_path")
  remark    String  @default("Hysteria2") @map("remark")
  isEnabled Boolean @default(true) @map("is_enabled")

  createdAt DateTime @default(dbgenerated("now()")) @map("created_at")
  updatedAt DateTime @default(dbgenerated("now()")) @updatedAt @map("updated_at")

  node Nodes @relation(fields: [nodeId], references: [id], onDelete: Cascade)

  @@map("hysteria2_inbounds")
}
```

**Важные детали:**
- `nodeId` — `@unique`: одна нода = один Hysteria 2 inbound.
- `onDelete: Cascade` — при удалении ноды inbound удаляется автоматически.
- `domain` и `sni` — разные поля, т.к. у Hysteria 2 домен для подключения и SNI могут различаться.

**После изменения схемы требуется создать и применить миграцию:**
```bash
cd remnawave-backend
npx prisma migrate dev --name add_hysteria2_inbound
```

---

### 3.2 Новый модуль `hysteria2-inbounds`

**Расположение:** `remnawave-backend/src/modules/hysteria2-inbounds/`

Структура модуля:
```
hysteria2-inbounds/
├── entities/
│   └── hysteria2-inbound.entity.ts
├── repositories/
│   └── hysteria2-inbound.repository.ts
├── dtos/
│   └── hysteria2-inbound.dto.ts
├── hysteria2-inbounds.service.ts
├── hysteria2-inbounds.controller.ts
└── hysteria2-inbounds.module.ts
```

#### Entity `hysteria2-inbound.entity.ts`

Имплементирует Prisma-тип `Hysteria2Inbound`:

```typescript
export class Hysteria2InboundEntity implements Hysteria2Inbound {
    public id: bigint;
    public nodeId: bigint;
    public port: number;
    public domain: string;
    public sni: string;
    public certPath: string;
    public keyPath: string;
    public remark: string;
    public isEnabled: boolean;
    public createdAt: Date;
    public updatedAt: Date;

    constructor(data: Hysteria2Inbound) {
        Object.assign(this, data);
    }
}
```

#### Repository `hysteria2-inbound.repository.ts`

Методы:

- `upsert(data)` — создаёт или обновляет inbound по `nodeId`. Используется и для создания и для редактирования — Frontend вызывает один эндпоинт.
- `findByNodeId(nodeId: bigint)` — находит inbound по ноде.
- `findAllEnabled()` — все inbound'ы с `isEnabled: true`. Используется при генерации подписок и sync.
- `deleteByNodeId(nodeId: bigint)` — удаляет inbound.

#### DTOs `hysteria2-inbound.dto.ts`

Request DTO с валидацией через Zod:

```typescript
// Создание/обновление inbound
UpsertHysteria2InboundDto: {
    nodeId: number (positive)
    port:   number (1–65535, default 8443)
    domain: string
    sni:    string
    certPath: string
    keyPath:  string
    remark:   string (default "Hysteria2")
    isEnabled: boolean (default true)
}
```

Response DTO возвращает те же поля, `id` и `nodeId` конвертируются из `bigint` в `number` (JSON-совместимость).

#### Service `hysteria2-inbounds.service.ts`

Зависимости: `Hysteria2InboundRepository`, `NodesRepository`, `UsersRepository`, `AxiosService`.

**Методы CRUD:**
- `upsert(data)` — обёртка над repository, конвертирует `nodeId: number → bigint`.
- `findByNodeId(nodeId)`, `findAllEnabled()`, `deleteByNodeId(nodeId)` — прямые обёртки.

**Методы синхронизации:**

`syncUsersToNode(nodeId: bigint)`:
1. Проверяет наличие и `isEnabled` у inbound для этой ноды.
2. Получает ноду из `NodesRepository.findFirstByCriteria({ id: nodeId })`.
3. Проверяет `node.isConnected` — если нода не подключена, пропускает.
4. Получает всех активных пользователей через `usersRepository.getActiveUsersForHysteria2Sync()`.
5. Маппит пользователей: `{ name: uuid, password: vlessUuid }`.
6. Вызывает `axios.syncHysteria2Users(users, node.address, node.port)`.

`syncUsersToAllNodes()`:
- Итерирует все enabled inbound'ы.
- Для каждого вызывает HTTP-запрос к соответствующей ноде.
- Используется при массовом изменении пользователей (зарезервирован для будущего использования).

#### Controller `hysteria2-inbounds.controller.ts`

Защищён `JwtDefaultGuard + RolesGuard` с ролями `ADMIN` и `API`.

| Метод | Путь | Описание |
|---|---|---|
| `POST` | `/hysteria2-inbounds` | Создать/обновить inbound для ноды |
| `GET` | `/hysteria2-inbounds` | Получить все enabled inbound'ы |
| `GET` | `/hysteria2-inbounds/:nodeId` | Получить inbound конкретной ноды |
| `DELETE` | `/hysteria2-inbounds/:nodeId` | Удалить inbound ноды |
| `POST` | `/hysteria2-inbounds/:nodeId/sync` | Принудительный sync пользователей на ноду |

#### Module `hysteria2-inbounds.module.ts`

```typescript
@Module({
    imports: [NodesModule, UsersModule],
    controllers: [Hysteria2InboundsController],
    providers: [Hysteria2InboundsService, Hysteria2InboundRepository],
    exports: [Hysteria2InboundsService],
})
export class Hysteria2InboundsModule {}
```

---

### 3.3 Регистрация модуля

**Файл:** `remnawave-backend/src/modules/remnawave-backend.modules.ts`

Добавлен импорт и регистрация:
```typescript
import { Hysteria2InboundsModule } from './hysteria2-inbounds/hysteria2-inbounds.module';

// В массиве imports:
Hysteria2InboundsModule,
```

---

### 3.4 `axios.service.ts`

**Файл:** `remnawave-backend/src/common/axios/axios.service.ts`

Добавлен метод `syncHysteria2Users`:

```typescript
public async syncHysteria2Users(
    users: Array<{ name: string; password: string }>,
    address: string,
    port: null | number,
): Promise<TResult<{ response: { isStarted: boolean; error: string | null } }>>
```

- URL формируется через существующий приватный метод `getNodeUrl(address, '/node/hysteria2/sync', port)`.
- Timeout: 30 секунд (дольше чем у Xray — т.к. перезапуск процесса может занять время).
- При ошибке возвращает `fail(ERRORS.NODE_ERROR_WITH_MSG)` — не бросает исключение.

---

### 3.5 `users.repository.ts`

**Файл:** `remnawave-backend/src/modules/users/repositories/users.repository.ts`

Добавлен метод для получения активных пользователей в формате, нужном для Hysteria 2:

```typescript
public async getActiveUsersForHysteria2Sync(): Promise<
    { uuid: string; vlessUuid: string; }[]
> {
    return await this.qb.kysely
        .selectFrom('users')
        .select(['uuid', 'vlessUuid'])
        .where('status', '=', USERS_STATUS.ACTIVE)
        .execute();
}
```

> Выбирает только два поля — минимальный запрос. `uuid` станет `name` в конфиге Hysteria 2, `vlessUuid` — `password`.

---

### 3.6 `users.module.ts`

**Файл:** `remnawave-backend/src/modules/users/users.module.ts`

Добавлен экспорт `UsersRepository`, чтобы `Hysteria2InboundsModule` мог его использовать:

```typescript
exports: [UsersRepository],
```

Ранее `exports` был пустым массивом.

---

### 3.7 `start-node.processor.ts`

**Файл:** `remnawave-backend/src/queue/_nodes/processors/start-node.processor.ts`

**Добавлен импорт:**
```typescript
import { Hysteria2InboundsService } from '@modules/hysteria2-inbounds/hysteria2-inbounds.service';
```

**Добавлен в конструктор:**
```typescript
private readonly hysteria2InboundsService: Hysteria2InboundsService,
```

**Добавлен вызов после успешного старта ноды** (fire-and-forget, не блокирует):
```typescript
// После блока if (!node.isConnected) { ... }

this.hysteria2InboundsService.syncUsersToNode(node.id).catch((err) => {
    this.logger.warn(`Hysteria2 sync failed for node ${node.uuid}: ${err}`);
});
```

> Выбран fire-and-forget намеренно: если sync Hysteria 2 упадёт, это не должно влиять на основной процесс регистрации старта ноды.

---

### 3.8 `nodes-queues.module.ts`

**Файл:** `remnawave-backend/src/queue/_nodes/nodes-queues.module.ts`

Добавлен импорт `Hysteria2InboundsModule` в список `imports` модуля очереди, чтобы `start-node.processor.ts` мог получить `Hysteria2InboundsService` через DI:

```typescript
import { Hysteria2InboundsModule } from '@modules/hysteria2-inbounds/hysteria2-inbounds.module';

// В createDomainQueueModule:
imports: [CqrsModule, Hysteria2InboundsModule],
```

---

### 3.9 Генератор подписок

#### `resolved-proxy-config.interface.ts` — изменён

**Файл:** `remnawave-backend/src/modules/subscription-template/resolve-proxy/interfaces/resolved-proxy-config.interface.ts`

Добавлен новый тип протокола:

```typescript
export type Hysteria2Protocol = {
    protocol: 'hysteria2';
    password: string;   // vlessUuid пользователя
    sni: string;
    port: number;
    address: string;
    remark: string;
    security: 'tls' | 'none';
};
```

И добавлен в union `ProtocolVariant`:
```typescript
export type ProtocolVariant =
    | VlessProtocol
    | TrojanProtocol
    | ShadowsocksProtocol
    | HysteriaProtocol
    | Hysteria2Protocol;  // ← добавлено
```

#### `xray.generator.service.ts` — изменён

**Файл:** `remnawave-backend/src/modules/subscription-template/generators/xray.generator.service.ts`

В метод `generateLink` добавлен `case 'hysteria2'`:

```typescript
case 'hysteria2':
    return this.buildHysteria2Link(host);
```

Добавлен новый приватный метод `buildHysteria2Link`:

```typescript
private buildHysteria2Link(
    host: Extract<ResolvedProxyConfig, { protocol: 'hysteria2' }>,
): string {
    const params: Record<string, unknown> = {};

    if (host.sni) params.sni = host.sni;
    if (host.security === 'none') params.insecure = '1';

    const query = this.buildQueryString(params);
    const queryStr = query ? `?${query}` : '';
    const remark = encodeURIComponent(host.remark);

    return `hy2://${host.password}@${host.address}:${host.port}${queryStr}#${remark}`;
}
```

Формат URI: `hy2://vlessUuid@domain:8443?sni=domain#Remark`

> Этот формат понимают v2rayN, NekoBox, Hiddify, Clash Meta и другие популярные клиенты.

#### `render-templates.service.ts` — изменён

**Файл:** `remnawave-backend/src/modules/subscription-template/render-templates.service.ts`

Добавлена зависимость `Hysteria2InboundsService` в конструктор.

В методе `generateSubscription` вместо прямой передачи `formattedHosts` в генераторы теперь вызывается `appendHysteria2Entries`:

```typescript
const allHosts = await this.appendHysteria2Entries(formattedHosts, user);
// далее allHosts передаётся во все генераторы
```

Добавлен приватный метод `appendHysteria2Entries(existing, user)`:

1. Получает все enabled inbound'ы из `hysteria2InboundsService.findAllEnabled()`.
2. Если нет ни одного — возвращает исходный список без изменений.
3. Для каждого inbound создаёт объект `ResolvedProxyConfig` с `protocol: 'hysteria2'`.
4. Возвращает `[...existing, ...hysteria2Entries]`.

**Важный момент:** `Clash`, `Singbox` и другие генераторы имеют `default: return null/false` в своих switch-кейсах — неизвестный протокол они просто пропустят. Только `xray.generator.service.ts` умеет обрабатывать `hysteria2` и сгенерирует `hy2://` URI.

#### `subscription-template.module.ts` — изменён

**Файл:** `remnawave-backend/src/modules/subscription-template/subscription-template.module.ts`

Добавлен `Hysteria2InboundsModule` в список импортов NestJS-модуля:

```typescript
imports: [CqrsModule, Hysteria2InboundsModule],
```

---

## 4. Что не реализовано и требует доработки

### 4.1 Учёт трафика (КРИТИЧНО)

**Проблема:** трафик, прошедший через Hysteria 2, не учитывается. Пользователи с активным `hy2://` будут потреблять трафик без списания лимита.

**Что нужно:**

Hysteria 2 поддерживает Traffic Stats API. В конфиг нужно добавить секцию:
```yaml
trafficStats:
  listen: 127.0.0.1:9999
  secret: some-secret
```

Запрос `GET /traffic?clear=true` вернёт:
```json
{
  "uuid-пользователя": { "tx": 1234, "rx": 5678 }
}
```

На ноде нужен метод `collectTraffic()` в `Hysteria2Service`, на backend — вызов этого метода в `record-user-usage.processor.ts` рядом с уже существующим сбором трафика Xray, с суммированием через `bulk-increment-used-traffic`.

### 4.2 Трафик пишется в ту же ноду

По архитектурному решению трафик Hysteria 2 суммируется с трафиком Xray под одним `nodeId`. Это означает: в графиках нет разбивки по протоколу, но лимиты пользователей работают корректно. Менять архитектуру не рекомендуется.

### 4.3 Frontend

UI для управления Hysteria 2 inbound не реализован. API готов, нужен только React-компонент в карточке ноды.

### 4.4 Prisma-миграция не сгенерирована

Файл миграции в `prisma/migrations/` отсутствует. Перед деплоем обязательно выполнить:
```bash
npx prisma migrate dev --name add_hysteria2_inbound
```
Или создать SQL-миграцию вручную и применить через `npx prisma migrate deploy`.

---

## 5. Переменные окружения

### Нода (`remnawave-node`)

| Переменная | Тип | Default | Описание |
|---|---|---|---|
| `HYSTERIA2_ENABLED` | boolean | `false` | Включить Hysteria 2. При `false` — сервис не стартует, процесс не запускается |
| `HYSTERIA2_PORT` | number | `8443` | UDP-порт для Hysteria 2. Открыть в firewall как UDP |
| `HYSTERIA2_CONFIG_PATH` | string | `/etc/hysteria2/config.yaml` | Путь к генерируемому конфигу |
| `HYSTERIA2_CERT_PATH` | string | `/etc/hysteria2/cert.pem` | Путь к TLS-сертификату внутри контейнера |
| `HYSTERIA2_KEY_PATH` | string | `/etc/hysteria2/key.pem` | Путь к TLS-ключу внутри контейнера |
| `HYSTERIA2_MASQUERADE_URL` | string | `https://news.ycombinator.com/` | URL для masquerade (маскировка трафика) |
| `HYSTERIA2_OBFS_PASSWORD` | string | `` (пустой) | Пароль для obfuscation (salamander). Если пустой — obfs отключён |

### Backend (`remnawave-backend`)

Новых переменных окружения нет. Настройка Hysteria 2 для каждой ноды хранится в БД через API.

---

## 6. Миграция БД

Необходимо выполнить после развёртывания кода:

```bash
cd remnawave-backend

# Development
npx prisma migrate dev --name add_hysteria2_inbound

# Production
npx prisma migrate deploy
```

SQL, который будет выполнен:

```sql
CREATE TABLE "hysteria2_inbounds" (
    "id"         BIGSERIAL PRIMARY KEY,
    "node_id"    BIGINT NOT NULL UNIQUE,
    "port"       INTEGER NOT NULL DEFAULT 8443,
    "domain"     TEXT NOT NULL,
    "sni"        TEXT NOT NULL,
    "cert_path"  TEXT NOT NULL,
    "key_path"   TEXT NOT NULL,
    "remark"     TEXT NOT NULL DEFAULT 'Hysteria2',
    "is_enabled" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT now(),
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT "hysteria2_inbounds_node_id_fkey"
        FOREIGN KEY ("node_id")
        REFERENCES "nodes"("id")
        ON DELETE CASCADE
);
```

---

## 7. API-справочник

### Нода (вызывается backend'ом)

Базовый URL: `https://<node-address>:<node-port>/node`

| Метод | Путь | Body | Описание |
|---|---|---|---|
| `POST` | `/hysteria2/sync` | `{ users: [{ name, password }] }` | Обновить пользователей и перезапустить процесс |
| `GET` | `/hysteria2/stop` | — | Остановить процесс |
| `GET` | `/hysteria2/status` | — | Получить статус процесса |

Пример ответа `/hysteria2/sync`:
```json
{
  "response": {
    "isStarted": true,
    "error": null
  }
}
```

Пример ответа `/hysteria2/status`:
```json
{
  "response": {
    "isRunning": true,
    "version": "2.6.1",
    "port": 8443,
    "error": null
  }
}
```

### Backend REST API (вызывается Frontend'ом или внешними клиентами)

Базовый URL: `https://<panel>/api`

| Метод | Путь | Body | Описание |
|---|---|---|---|
| `POST` | `/hysteria2-inbounds` | `UpsertHysteria2InboundDto` | Создать или обновить inbound |
| `GET` | `/hysteria2-inbounds` | — | Получить все enabled inbound'ы |
| `GET` | `/hysteria2-inbounds/:nodeId` | — | Получить inbound конкретной ноды |
| `DELETE` | `/hysteria2-inbounds/:nodeId` | — | Удалить inbound |
| `POST` | `/hysteria2-inbounds/:nodeId/sync` | — | Принудительный sync пользователей |

Пример тела запроса `POST /hysteria2-inbounds`:
```json
{
  "nodeId": 1,
  "port": 8443,
  "domain": "cdn.example.com",
  "sni": "cdn.example.com",
  "certPath": "/etc/hysteria2/cert.pem",
  "keyPath": "/etc/hysteria2/key.pem",
  "remark": "Germany Hysteria2",
  "isEnabled": true
}
```
