# Engineering Guidelines

Internal standards for the `server-manager` repository.
These rules are non-negotiable. Exceptions require explicit justification in PR description.

---

## 1. Bash vs Python

### Запрещено в Bash категорически

- `python3 << EOF` — heredoc с Python-кодом
- `python3 -c "..."` — более одной логической операции в строке
- `cat > script.py << EOF` — генерация Python-файлов из Bash
- `awk`, `sed` для парсинга или модификации YAML/JSON/TOML конфигов
- SQL в любом виде — в том числе через `docker exec psql`
- `echo >> file.env` и `sed -i` для обновления ENV-файлов
- Многострочная бизнес-логика: условия, циклы по данным, строковые трансформации

### Обязательно выносится в Python

- Любое чтение или запись JSON, YAML, TOML
- Любые операции с `.env` файлами (чтение, upsert, удаление ключей)
- Хэширование, криптографические операции
- SQL-запросы (psycopg2, sqlite3)
- Парсинг вывода внешних команд если результат используется как данные
- Патчинг исходного кода других скриптов

### Допустимые исключения

- `python3 -c "import module"` — проверка наличия модуля (однострочник, нет логики)
- `grep -q "pattern" file` — булева проверка наличия строки, результат не парсится
- `cut`, `tr`, `head` — только для форматирования вывода уже корректных данных, не для извлечения структуры

---

## 2. Runtime компоненты

### Определения

| Тип | Описание | Пример |
|-----|----------|--------|
| `service` | Работает непрерывно. Управляется `systemd service`. | `hy-webhook.py` |
| `job` | Запускается по расписанию. Управляется `systemd timer`. | `hy_traffic_collect.py`, `collect_stats.py` |
| `one-shot` | Запускается один раз при установке. Bash вызывает напрямую. | `hy_node_register.py` |

### Где живут

```
integrations/       — runtime-компоненты уровня Hysteria2/Remnawave
lib/tmt/py/         — runtime-компоненты уровня telemt
scripts/            — вспомогательные установочные скрипты (не daemon)
```

Daemon-треды внутри service — допустимы если:
- компонент stateless (нет pending-файла, нет транзакций)
- данные эфемерны (потеря одного цикла допустима)
- файл компонента самодостаточен (читает ENV сам, имеет `if __name__ == "__main__"`)

### Чек-лист добавления нового компонента

- [ ] Файл создан в правильной директории (`integrations/` или `lib/*/py/`)
- [ ] Контракт описан в `docs/CONTRACTS.md`
- [ ] Все зависимости читаются через `os.environ.get()` внутри файла (не через globals родительского модуля)
- [ ] Присутствует `if __name__ == "__main__"` точка входа
- [ ] Для `job`: unit-файлы `.service` + `.timer` созданы и устанавливаются при `install`
- [ ] Для `job`: компонент удаляется при `uninstall` (`systemctl disable --now`, `rm unit-files`)
- [ ] Для `service`-thread: компонент вынесен в отдельный файл и импортируется функцией `run()`
- [ ] Секция добавлена в таблицу runtime-компонентов в `docs/ENGINEER.md`

---

## 3. Контракты

### Область применения контрактов

Контракт в `docs/CONTRACTS.md` обязателен для:
- runtime-компонентов (`service`, `job`, `one-shot`, daemon-thread)
- любого скрипта, который вызывается из Bash

Не обязателен для:
- внутренних helper-модулей, импортируемых только другими Python-файлами (например `_update_env_file`, `_atomic_write`)

### Что считается валидным контрактом

Каждый Python-скрипт в `integrations/` и `lib/*/py/` обязан иметь запись в `docs/CONTRACTS.md` со следующей структурой:

```
Тип:        service | job | one-shot | thread
Файл:       путь от корня репозитория

ENV:
  NAME      [required|optional]   описание, default если optional

stdin:      none | описание формата
stdout:     none | описание формата (plain, JSON schema)
stderr:     human-readable errors only

Exit codes:
  0   успех
  1   конкретная причина
  2   другая причина
  ...

Идемпотентность: да/нет + краткое объяснение
```

### Обязательные требования к скрипту

- Exit code 0 означает только успех. Любая ошибка — ненулевой код.
- Разные классы ошибок — разные коды (недоступен API ≠ ошибка БД ≠ не установлена зависимость).
- `stderr` — только для ошибок и диагностики. `stdout` — только для данных.
- JSON на stdout не смешивается с человекочитаемым текстом.
- Bash проверяет exit code после каждого вызова. Игнорирование exit code запрещено.

---

## 4. Работа с конфигами и ENV

### Обновление `.env` файлов

- Только через Python-утилиту с атомарной записью (`tempfile` + `os.replace()`).
- Функция `_update_env_file(path, updates: dict)` — единственный разрешённый способ.
- Запрещено: `echo "KEY=val" >> file.env`, `sed -i 's/KEY=.*/KEY=val/'`, прямая запись через `>`.

### Обновление YAML/TOML конфигов

- Только через Python (соответствующий `hy_config.py` или аналог).
- `cat > config.yaml << EOF` — допустим только для первичного создания файла при установке, если файл ещё не существует и содержимое является шаблоном без логики.
- Запрещено использовать `cat >>` для добавления секций в существующий конфиг.

### Atomicity

- Любая запись файла: `tempfile` → заполнить → `os.replace()`. Никаких прямых `open(path, 'w')` для файлов которые читают другие процессы.
- Запрещено `open(path, "w")` для: `.env`, `config.yaml`, `users.json` и любых файлов, к которым обращаются другие процессы или systemd-сервисы.
- Единственный разрешённый паттерн записи таких файлов:

```python
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
```

---

## 5. Работа с базами данных

### Где разрешён SQL

- Только в Python-файлах с явным контрактом.
- SQLite: через `sqlite3` стандартной библиотеки, WAL-режим обязателен (`PRAGMA journal_mode=WAL`).
- PostgreSQL: только через `psycopg2`, только в `integrations/` или `lib/*/py/`.

### Где SQL запрещён

- В `.sh` файлах — категорически, в любом виде.
- Через `docker exec ... psql` — запрещено.
- Inline в heredoc внутри Bash — запрещено.

### Требования к идемпотентности

- INSERT: всегда с `ON CONFLICT DO UPDATE` или `ON CONFLICT DO NOTHING` если семантика позволяет.
- Любой скрипт типа `one-shot` или `job` обязан быть безопасным при повторном запуске.
- Транзакция обязательна если скрипт делает более одного write-запроса: `BEGIN` → операции → `COMMIT`, при ошибке — `ROLLBACK`.

---

## 6. Resilience

Применяется ко всем `service`, `job` и daemon-thread компонентам.

- Временные ошибки (HTTP timeout, DB connection error, filesystem) не должны роняться процесс. Исключение перехватывается, ошибка логируется, цикл продолжается.
- Потеря одного цикла — допустима. Падение процесса из-за временной ошибки — нет.
- Для `job` (systemd oneshot): при недоступности внешнего ресурса — exit с ненулевым кодом, systemd зафиксирует ошибку в journal. Retry обеспечивает таймер.
- Для daemon-thread внутри `service`: `while True` обязан содержать `except Exception`, иначе упавший поток убивает весь процесс незаметно.

```python
# Обязательный паттерн для цикла daemon-thread:
while True:
    time.sleep(interval)
    try:
        do_work()
    except Exception as e:
        log.warning(f"Cycle skipped: {e}")  # не re-raise
```

---

## 7. Logging

- Использовать только `logging` (стандартная библиотека). `print()` для логов запрещён.
- `stdout` — только для данных, предусмотренных контрактом (plain text, JSON).
- Диагностика, предупреждения, ошибки — только в `stderr` / systemd journal.
- Инициализация в каждом скрипте:

```python
import logging, sys
log = logging.getLogger(__name__)
# В __main__ блоке:
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler()],
)
```

- Уровни: `DEBUG` для цикличных операций (каждый poll), `INFO` для значимых событий (запуск, результат), `WARNING` для пропущенных циклов, `ERROR` для сбоев требующих внимания.

---

## 8. Dependencies

- Каждый скрипт, использующий внешние зависимости (`psycopg2`, `yaml`, `requests` и т.д.), обязан явно перехватывать `ImportError`.
- Отсутствие зависимости — отдельный exit code (по соглашению: `3`).
- Скрипт не должен падать с `ModuleNotFoundError` — это неявный сбой без диагностики в journal.

```python
# Обязательный паттерн:
try:
    import psycopg2
except ImportError:
    log.error("psycopg2 not installed. Run: pip install psycopg2-binary")
    sys.exit(3)
```

- Exit code `3` резервируется для "зависимость не установлена" во всех скриптах проекта.
- Bash после вызова скрипта обязан обрабатывать этот код явно:

```bash
python3 "${SCRIPT_DIR}/integrations/hy_traffic_collect.py"
local _rc=$?
[ $_rc -eq 3 ] && { warn "psycopg2 не установлен — запустите установку зависимостей"; return 1; }
[ $_rc -ne 0 ] && { warn "Сбор трафика завершился с ошибкой (exit $_rc)"; return 1; }
```

---

## 9. Правило тонкого Bash-слоя

**Bash знает *где* и *когда*. Python знает *что*.**

Если Bash-функция содержит более трёх строк обработки данных (парсинг, трансформация, условия над содержимым файлов) — она написана неправильно и должна быть перенесена в Python-скрипт с ENV-контрактом.

---

---

## 10. CLI Execution Model

Применяется ко всем файлам в `lib/cli/`.

### stdout / stderr контракт

```
stdout → ТОЛЬКО финальные данные команды:
           cli_result_ok [message] [json_data]
           cli_exec_py_stream (raw вывод скрипта — list, status, render)

stderr → ВСЁ остальное:
           cli_ok / cli_warn / cli_err / cli_dry / cli_info
           cli_result_err
```

Следствие — automation работает предсказуемо:
```bash
sm hy2 user add --name alice --json 2>/dev/null  # чистый JSON, без [OK]/[WARN]
sm hy2 user list --json | jq '.[].user'          # pipe без фильтрации мусора
sm panel status 2>/dev/null                       # только данные, без диагностики
```

### Режимы выполнения Python-скриптов

| Режим | Функция | Когда использовать |
|-------|---------|-------------------|
| stream | `cli_exec_py_stream` | stdout скрипта — финальный вывод пользователю (list, status, render) |
| capture | `cli_exec_py_capture` | stdout скрипта — значение для использования внутри команды |

**Запрещённый паттерн:**
```bash
# ЗАПРЕЩЕНО: subshell теряет _CLI_EXEC_RC, _CLI_EXEC_STDERR, dry-run не работает
value=$(cli_exec_py_stream "description" python3 script.py)
value=$(cli_exec_py "description" python3 script.py)
```

**Правильный паттерн для значений:**
```bash
# capture: stdout → _CLI_EXEC_STDOUT, обработка ошибок сохраняется
cli_exec_py_capture "Getting auth mode" \
    HY_CONFIG="$HYSTERIA_CONFIG" \
    python3 "${SCRIPT_DIR}/lib/hy2/py/hy_config.py" get-auth-mode
cli_exec_py_check || exit $?
auth_mode="$_CLI_EXEC_STDOUT"
```

**Правильный паттерн для вывода данных:**
```bash
# stream: stdout скрипта идёт напрямую в stdout процесса
cli_exec_py_stream "Listing users" \
    HY_USERS_DB="$db" \
    python3 "${SCRIPT_DIR}/lib/hy2/py/hy_users_db.py" list
cli_exec_py_check || exit $?
# вывод уже у пользователя — cli_result_ok не нужен
```

### Финальный вывод команды

- Каждая CLI-команда **обязана** завершаться через `cli_result_ok` или `cli_result_err`.
- Прямые `echo`, `printf`, `cli_ok` в качестве финального вывода запрещены.
- Исключение: команды типа `list`/`status`, где финальные данные выводит `cli_exec_py_stream` — `cli_result_ok` после него не нужен.

```bash
# ЗАПРЕЩЕНО:
echo "User added"
printf '[OK] User %s added\n' "$name"
cli_ok "User added"          # это диагностика, не результат

# РАЗРЕШЕНО:
cli_result_ok "User '${name}' added" "{\"user\":\"${name}\"}"
cli_result_err "User '${name}' not found" 7
```

### Правило выбора stream vs capture (одно предложение)

Если вывод скрипта читает пользователь — `stream`. Если вывод скрипта читает следующая строка кода — `capture`.

---

## Быстрая проверка перед коммитом

```bash
# Ни одного из этих паттернов не должно быть в .sh файлах:
grep -rn \
  -e 'python3 <<' \
  -e 'python3 -c ".*\n' \
  -e 'cat > .*\.py' \
  -e 'docker exec.*psql' \
  -e 'echo.*>> .*\.env' \
  -e "sed -i.*\.env" \
  lib/ integrations/

# Запрещённый паттерн записи файлов в Python:
grep -rn 'open(.*["\x27]\(\.env\|config\.yaml\|users\.json\)["\x27].*["\x27]w["\x27]' \
  integrations/ lib/

# Запрещённые паттерны в CLI-слое:
grep -rn \
  -e '\$(cli_exec_py' \
  -e '\$(cli_exec_py_stream' \
  -e '\$(cli_exec_py_capture' \
  lib/cli/
# → 0 результатов (capture через subshell теряет контекст)

grep -rn \
  -e "^\s*echo " \
  -e "^\s*printf " \
  lib/cli/ \
  | grep -v "cli_result_ok\|cli_result_err\|cli_ok\|cli_warn\|cli_err\|cli_dry\|cli_info\|cli_usage\|HELP\|USAGE\|#"
# → только допустимые вызовы print-хелперов

# Каждый новый .py в integrations/ или lib/*/py/ должен быть в CONTRACTS.md:
for f in integrations/*.py lib/*/py/*.py; do
  basename "$f" | xargs -I{} grep -ql "{}" docs/CONTRACTS.md \
    || echo "MISSING CONTRACT: $f"
done
```
