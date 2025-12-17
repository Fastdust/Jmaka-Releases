# Jmaka Releases

Этот репозиторий публичный и предназначен только для удобного скачивания релизов Jmaka одной командой.

## Установка на Ubuntu 24 (одной командой)
Команда всегда скачивает *последний* релиз:

```bash
curl -L -o ~/jmaka.tar.gz \
  https://github.com/Fastdust/Jmaka-Releases/releases/latest/download/jmaka-linux-x64.tar.gz \
&& curl -L -o ~/jmaka.sh \
  https://raw.githubusercontent.com/Fastdust/Jmaka-Releases/main/jmaka.sh \
&& curl -L -o ~/install.sh \
  https://raw.githubusercontent.com/Fastdust/Jmaka-Releases/main/install.sh \
&& curl -L -o ~/jmaka-reset.sh \
  https://raw.githubusercontent.com/Fastdust/Jmaka-Releases/main/jmaka-reset.sh \
&& curl -L -o ~/nginx-backup.sh \
  https://raw.githubusercontent.com/Fastdust/Jmaka-Releases/main/nginx-backup.sh \
&& curl -L -o ~/nginx-restore.sh \
  https://raw.githubusercontent.com/Fastdust/Jmaka-Releases/main/nginx-restore.sh \
&& bash ~/jmaka.sh
```

Примечания:
- Архив скачивается в `~/jmaka.tar.gz`.
- Установщик сам запросит sudo и разложит файлы по стандартным директориям (`/var/www/jmaka/...`).
- Если нужно установить в подпапку (например `/jmaka/` на существующем домене) — выберите `path prefix` в мастере.
  - Режим `base-path` (рекомендуется): приложение получает URI с префиксом `/jmaka`, nginx `proxy_pass` без завершающего `/`.
  - Режим `strip-prefix` (legacy): nginx отрезает `/jmaka` (в `proxy_pass` есть завершающий `/`), приложение работает как на корне `/`.
- Режим nginx `AUTO` (по умолчанию) сам:
  - создаёт snippet `/etc/nginx/snippets/jmaka-<name>.location.conf`
  - добавляет `include ...` в существующий vhost домена
  - использует `location ^~ /jmaka/ { ... }`, чтобы не ловить 404 на `/jmaka/crop`

## Служебные скрипты
- `nginx-backup.sh` — простой бэкап `/etc/nginx` в `~/jmaka-backups/nginx/`.
- `nginx-restore.sh` — восстановление `/etc/nginx` из tar.gz бэкапа.
- `jmaka-reset.sh` — удалить все инстансы Jmaka и убрать внесённые include/snippet (с бэкапами изменяемых файлов).

## Assets
- `jmaka-linux-x64.tar.gz` — linux-x64 архив приложения (framework-dependent), который прикрепляется к каждому релизу как стабильное имя для `releases/latest/download/...`.

## Security
Основной код приложения может быть в приватном репозитории. Этот репозиторий содержит только установщик и опубликованные артефакты.