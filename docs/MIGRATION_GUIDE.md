# Гайд: миграция на другой сервер (server-manager)

Этот документ — практический сценарий переноса сервисов через меню `server-manager`:

- Remnawave Panel
- MTProxy (telemt)
- Hysteria2
- Полный перенос всего стека

---

## 1) Перед началом: чек-лист

### Что подготовить

1. **Новый сервер** с доступом по SSH (IP, порт, пользователь, пароль).  
2. **Открытые порты** (минимум SSH, и порты ваших сервисов).  
3. **Одинаковая архитектура/ОС** желательно (Debian/Ubuntu x86_64/aarch64).  
4. **Домен/SSL**:
   - для Panel: домен, DNS-запись на новый IP;
   - для MTProxy: домен-маскировка (`tls_domain`) если используете.

### Что сохранить заранее (рекомендуется)

- `Panel`: `/opt/remnawave/.env`, `/opt/remnawave/docker-compose.yml`, `nginx.conf`/`Caddyfile`, SSL.
- `MTProxy`: `/etc/telemt/telemt.toml`.
- `Hysteria2`: `/etc/hysteria/config.yaml`, URI-файлы `hysteria-*.txt`.

---

## 2) Как открыть меню миграции

1. Запустите скрипт:
   ```bash
   server-manager
   ```
2. Перейдите:
   - `📦 Перенос сервисов`

Далее доступны:

- `1) Перенести Remnawave Panel`
- `2) Перенести MTProxy (telemt)`
- `3) Перенести Hysteria2`
- `4) Перенести всё`

---

## 3) MTProxy (telemt): рекомендуемый порядок

### Если переносите только MTProxy

Используйте:

- `📦 Перенос сервисов → 2) Перенести MTProxy (telemt)`

Что важно:

- В prompt домен подставляется из текущего `telemt.toml`;  
  Enter оставляет текущий домен.
- Переносятся пользователи и лимиты (включая expirations в новом формате).
- После запуска на новом сервере проверьте:
  ```bash
  systemctl status telemt --no-pager
  curl -s http://127.0.0.1:9091/v1/users
  ```

### Если раньше уже переносили, а expirations не перенеслись

После обновления скрипта **повторите миграцию MTProxy** (пункт 2)  
или вручную убедитесь, что в `telemt.toml` присутствуют:

- `[access.user_expirations]`
- `[access.user_max_tcp_conns]`
- `[access.user_data_quota]`
- `[access.user_max_unique_ips]`

и перезапустите:
```bash
systemctl restart telemt
```

---

## 4) Полный перенос (Panel + MTProxy + Hysteria2)

Используйте:

- `📦 Перенос сервисов → 4) Перенести всё`

Скрипт выполняет:

1. Проверку SSH и установку зависимостей на новом сервере.
2. Panel:
   - дамп БД;
   - копирование конфигов/SSL;
   - восстановление и запуск.
3. MTProxy:
   - генерацию `telemt.toml` с пользователями;
   - перенос блоков лимитов/expirations;
   - установку telemt и запуск systemd unit.
4. Hysteria2:
   - перенос `config.yaml` и связанных файлов;
   - установку/перезапуск на новом сервере.

---

## 5) Runtime-статистика после миграции (telemt)

В скрипте есть накопительный учёт:

- `Трафик` — текущее значение telemt (`total_octets`)
- `Собрано` — накопленное значение с учётом сбросов runtime счётчика

Новые пункты меню:

- `👥 Пользователи → 🌐 IP история пользователя`
- `👥 Пользователи → ⚙️ Настройки сбора (трафик/IP)` (retention дней)

Где хранится статистика:

- systemd: `/var/lib/telemt/traffic-usage.json`
- docker: `${HOME}/mtproxy/traffic-usage.json`

---

## 6) Проверка после миграции

### Panel
```bash
cd /opt/remnawave
docker compose ps
docker compose logs --tail=100
```

### MTProxy
```bash
systemctl status telemt --no-pager
curl -s http://127.0.0.1:9091/v1/users | head
```

### Hysteria2
```bash
systemctl status hysteria-server --no-pager
journalctl -u hysteria-server -n 50 --no-pager
```

---

## 7) Быстрый rollback-план

Если что-то пошло не так:

1. Не выключайте старый сервер сразу.
2. Верните DNS на старый IP.
3. Остановите новый сервис (по необходимости), исправьте конфиг.
4. Повторите миграцию только проблемного компонента (Panel/MTProxy/Hysteria2).

---

## 8) Частые вопросы

### Трафик telemt “сбрасывается” — это нормально?
Да. Runtime счётчик telemt может начинаться заново после перезапуска/переустановки.  
Для этого и добавлен накопительный `Собрано` в локальной базе статистики.

### Можно ли хранить IP-историю ограниченное время?
Да. Настраивается в меню `Настройки сбора (трафик/IP)` в днях.

