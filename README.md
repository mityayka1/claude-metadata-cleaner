# Claude Metadata Cleaner

Bash-скрипт для удаления выбранных локальных идентификаторов и OAuth-кэшей Claude. Требуются **Bash и Python 3**. Проверен на macOS; предусмотрены стандартные пути Linux и переменные `APPDATA` / `LOCALAPPDATA` (Windows отдельно не тестировался).

## Запуск

```bash
# Предварительный просмотр, без изменений
bash clean-claude-metadata.sh

# Закройте Claude Desktop и Claude Code перед применением
bash clean-claude-metadata.sh --apply

# Дополнительное дерево поиска или конкретный каталог конфигурации
bash clean-claude-metadata.sh --search "/path/to/search"
bash clean-claude-metadata.sh --root "/path/to/config"

# Только стандартные каталоги и явно заданные --root
bash clean-claude-metadata.sh --no-search
```

`--search` и `--root` можно повторять и сочетать с `--apply`. По умолчанию проверяются стандартные пути, `CLAUDE_CONFIG_DIR` и домашний каталог. Кэши, зависимости, история сессий и резервные копии самого скрипта исключены из обхода. Недоступные каталоги отмечаются предупреждениями; симлинки и образы VM не обходятся.

## Что меняется

В найденных семействах `.claude.json`, `config.json`, `remote-control-state.json` и их копиях удаляются поля `machineID`, `userID`, `anonymousId`, `pairedDeviceId`, `chromeExtension.pairedDeviceId`, `first_launch_at`, `version_first_launch`, `lastKnownAccountUuid`, `oauth:tokenCache`, `oauth:tokenCacheV2`, `telemetrySalt`. Также удаляется `bootSideSessions.accountUuid` в `config.json`, очищается `identities` в `remote-control-state.json`, реестр `ant-device-registry.json` и удаляется файл `ant-did`.

Остальные JSON-поля сохраняются; отступы приводятся к двум пробелам. История сессий сохраняется. Поддерживается распознанный формат `.journal` с проверкой и пересчётом SHA-256; неизвестный формат или некорректный JSON останавливает работу до записи.

Перед изменениями все затрагиваемые файлы копируются в закрытый каталог `~/.local/state/claude-metadata-backups/<дата-время-суффикс>/` с сохранением дерева исходных путей. Копии содержат исходные идентификаторы и учётные данные. Для восстановления закройте Claude и верните нужные файлы из указанной копии на исходные места.

Каждый файл заменяется атомарно; весь набор файлов не является единой транзакцией. Удаление OAuth-кэшей может потребовать повторного входа. Скрипт не гарантирует предотвращение блокировок и не удаляет все возможные следы устройства.
