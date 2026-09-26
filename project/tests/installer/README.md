# OUO installer checks

These checks run the installer in isolated temporary directories. They never
touch the repository `.env`, current Docker containers, or persisted node data.

```bash
tests/installer/run --all
tests/installer/run --dry-run
tests/installer/run --matrix
tests/installer/run --negative
```

The current suite verifies dry-run immutability, the four public/private ×
admin/headless configurations, restrictive file permissions, required owner
artifacts, invalid domain rejection, and idempotent secret preservation.

Пользовательский релиз поставляется архивом с каталогом `project/`. После
распаковки достаточно выполнить `./install`: Git на целевой машине не нужен.
Мастер объясняет выбранный режим, создаёт секреты, сохраняет `.env` с правами
0600 и по подтверждению запускает только выбранные сервисы.
