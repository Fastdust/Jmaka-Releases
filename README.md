# Jmaka Releases

Этот репозиторий публичный и предназначен только для удобного скачивания релизов Jmaka одной командой.

## Установка на Ubuntu 24 (одной командой)
Команда всегда скачивает *последний* релиз:

```bash
curl -L -o ~/jmaka.tar.gz \
  https://github.com/Fastdust/Jmaka-Releases/releases/latest/download/jmaka-linux-x64.tar.gz \
&& curl -L -o ~/jmaka-install.sh \
  https://raw.githubusercontent.com/Fastdust/Jmaka-Releases/main/install.sh \
&& bash ~/jmaka-install.sh --interactive
```

Примечания:
- Архив скачивается в `~/jmaka.tar.gz`.
- Установщик сам запросит sudo и разложит файлы по стандартным директориям (`/var/www/jmaka/...`).
- Если нужно установить в подпапку (например `/jmaka/` на существующем домене) — выберите `path prefix` в мастере.
  - Режим `base-path` (рекомендуется): приложение получает URI с префиксом `/jmaka`, nginx `proxy_pass` без завершающего `/`.
  - Режим `strip-prefix` (legacy): nginx отрезает `/jmaka` (в `proxy_pass` есть завершающий `/`), приложение работает как на корне `/`.
- Перед установкой мастер предлагает очистить следы прошлых установок (по инстансу или все сразу).

## Assets
- `jmaka-linux-x64.tar.gz` — linux-x64 архив приложения (framework-dependent), который прикрепляется к каждому релизу как стабильное имя для `releases/latest/download/...`.

## Security
Основной код приложения может быть в приватном репозитории. Этот репозиторий содержит только установщик и опубликованные артефакты.