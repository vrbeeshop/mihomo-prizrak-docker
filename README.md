# Prizrak-Core в Docker и на роутере

Форк [mihomo-mikrotik](https://github.com/wiktorbgu/mihomo-mikrotik), переведённый на [Prizrak-Core](https://github.com/legiz-ru/Prizrak-Core). Контейнер собирает ядро из исходников и сохраняет формат конфигурации mihomo, переменные подписок и каталог `/etc/mihomo`.

Prizrak-Core добавляет к mihomo возможности Xray: XHTTP, REALITY с ML-DSA-65, mux.cool, finalmask и mKCP для VLESS. Также доступны протоколы ядра, включая VLESS, Trojan, Hysteria2, TUIC, Shadowsocks и WireGuard. Параметры конкретного сервера должны поддерживаться выбранной версией ядра; см. [официальную документацию](https://core.prizrak.app/ru/).

Версия проекта — **0.1.0**, она записана в `VERSION`. По умолчанию образ собирает чистый тег ядра Prizrak-Core **v1.19.34-r2** без локальных патчей. Версия проекта и версия ядра задаются независимо.

## Быстрый запуск на домашнем сервере

Выберите один способ запуска для экземпляра: Docker Compose ниже или `docker run` в следующем разделе.

Нужны Linux и Docker Engine с поддержкой BuildKit. Для этого сценария также нужен Docker Compose.

```bash
cp .env.example .env
```

Задайте свой `UI_SECRET` в `.env` и добавьте `SUB1` с HTTP(S)-URL подписки либо `SRV1` со ссылкой узла. Затем:

```bash
docker compose up --build -d
docker compose logs -f prizrak
```

Данные сохраняются в `./data`. Без подписок и узлов используется `DIRECT`: контейнер запускается, но трафик идёт напрямую.

| Сервис | Адрес на сервере |
| --- | --- |
| HTTP / SOCKS5 | `127.0.0.1:1080` TCP и UDP |
| API управления | `127.0.0.1:9090` TCP |
| DNS внутри контейнера | `0.0.0.0:1053`, наружу не опубликован |

Веб-панель в образ не включена: при первом запуске ядро скачивает MetaCubeXD в `./data/ui` и отдаёт её по адресу `http://127.0.0.1:9090/ui/`. Для загрузки нужен доступ к GitHub. Можно задать `EXTERNAL_UI_URL` с архивом другой совместимой панели либо подключить клиент к API с `UI_SECRET`. В стандартном Compose порты доступны только с самого сервера. Для устройств LAN адрес публикации и правила firewall задаются отдельно.

Проверка HTTP-прокси:

```bash
curl --proxy http://127.0.0.1:1080 https://example.org/
```

Обычный режим не требует `NET_ADMIN` и `/dev/net/tun`; стартовый скрипт не меняет NAT и policy routing. Проксирование применяется к приложениям, в которых указан этот прокси.

## Docker run без Compose

Соберите образ с фиксированной версией ядра и подготовьте окружение:

```bash
docker build --build-arg PRIZRAK_VERSION=v1.19.34-r2 \
  -t mihomo-prizrak-docker:local .
cp .env.example .env
mkdir -p data
```

Замените `UI_SECRET` и добавьте свою подписку в `SUB1` внутри `.env`. Затем запустите контейнер:

```bash
docker run -d --name prizrak --restart unless-stopped \
  --env-file .env \
  -p 127.0.0.1:1080:1080/tcp \
  -p 127.0.0.1:1080:1080/udp \
  -p 127.0.0.1:9090:9090/tcp \
  --mount type=bind,source="$(pwd)/data",target=/etc/mihomo \
  mihomo-prizrak-docker:local
docker logs -f prizrak
```

Прокси и панель доступны по тем же адресам, что и в Compose. `Ctrl+C` завершает просмотр логов; остановка и удаление контейнера выполняются отдельно:

```bash
docker stop prizrak
docker rm prizrak
```

Данные остаются в `./data`. После изменения `.env` пересоздайте контейнер той же командой `docker run`. Параметры сборки для этого сценария передаются через `docker build --build-arg`; переменные в `--env-file` применяются при запуске.

## Режимы сети

| `NETWORK_MODE` | Назначение |
| --- | --- |
| `proxy` | Режим по умолчанию: HTTP/SOCKS без автоматического перехвата трафика |
| `tun` | TUN с маршрутизацией средствами ядра; нужны `/dev/net/tun` и `NET_ADMIN` |
| `tproxy` | Прозрачный прокси через nftables и policy routing; трафик должен поступать на выбранный интерфейс |
| `mikrotik` | Подготовка сети RouterOS: NAT, исправление policy rules, multi-VETH и выбор TPROXY/TUN по доступности nftables |

`compose.yaml` явно выбирает `proxy`. Отдельный файл `compose.tun.yaml` выбирает `tun`, использует сеть хоста и оставляет HTTP/SOCKS, API и DNS на loopback. Он меняет маршрутизацию **самого Linux-сервера** при включённом `TUN_AUTO_ROUTE=true`.

Переключение на TUN после настройки подписки:

```bash
docker compose down
docker compose -f compose.tun.yaml up --build -d
docker compose -f compose.tun.yaml logs -f prizrak
```

Используйте `compose.tun.yaml` самостоятельно, без объединения с `compose.yaml`. Для возврата остановите его через `docker compose -f compose.tun.yaml down` и запустите обычный Compose.

TUN сервера сам по себе не делает его шлюзом для LAN. Для перехвата трафика других устройств требуются настройки шлюза, forwarding и firewall. В `tproxy` доступны `TPROXY_INTERFACE` и `TPROXY_PORT` (по умолчанию `15123`); этот режим требует nftables и `NET_ADMIN`. `TUN_AUTO_REDIRECT` по умолчанию выключен.

## Подписки и собственные конфигурации

В `.env` можно задать несколько `SUB1`, `SUB2`, … с обычными HTTP(S)-URL подписок и `SRV1`, `SRV2`, … с поддерживаемыми ядром URI узлов. HTTP(S)-URL в `SRVn` тоже обрабатываются как подписки. Содержимое подписок в форматах URI, YAML и Xray JSON разбирает само ядро. Для специфичных параметров Prizrak-Core используйте YAML: преобразователь ссылок провайдера должен уметь передавать эти параметры.

Каталог `./data` соответствует `/etc/mihomo`:

| Путь | Назначение |
| --- | --- |
| `default_config.yaml` | Сгенерированная конфигурация; ручные изменения перезаписываются |
| `template/default_config.yaml` | Поставляемый шаблон, обновляется из образа с резервной копией `default_config_old.yaml` |
| `config.yaml` | Готовая собственная конфигурация при `CONFIG=config.yaml`; без `envsubst` |
| `template/custom.yaml` | Собственный шаблон с переменными окружения при `CONFIG=custom.yaml` |
| `awg/*.conf` | Конфигурации WireGuard / AmneziaWG, преобразуемые в провайдер |
| `user_sh/*.sh` | Пользовательские скрипты, выполняемые при обычном старте |
| `.hwid` | Постоянный идентификатор для подписок с привязкой к устройству |

Чтобы изменить правила маршрутизации или группы, используйте собственный конфиг либо собственный шаблон. В готовом YAML вы сами задаёте listeners, DNS, API и секрет: переменные стандартного шаблона его не изменяют.

Полезные настройки стандартного шаблона: `LOG_LEVEL`, `IPV6`, `DNS`, `DNS_BOOTSTRAP`, `DNS_LISTEN`, `MIXED_PORT`, `UI_PORT`, `UI_SECRET`. Несколько DNS-серверов разделяются `|`. У провайдеров есть общий и индивидуальный `PROVIDER_HEADER`, `PROVIDER_FILTER`, `PROVIDER_EXCLUDE_FILTER`; индивидуальные имена заканчиваются, например, на `_SUB1`.

Проверка конфигурации без запуска перехвата:

```bash
docker compose run --rm prizrak --render-config
docker compose run --rm prizrak -t -d /etc/mihomo -f /etc/mihomo/default_config.yaml
```

`--render-config` создаёт конфигурацию без изменения сети и выполнения `user_sh`. Аргументы ядра, включая `-v`, `-h` и `-t`, передаются напрямую; при таком запуске генерации конфигурации нет.

## Сборки и архитектуры

Для самостоятельной сборки доступны варианты:

| Вариант | `WITH_GVISOR` | `UPX` |
| --- | --- | --- |
| Standard | `0` | `0` |
| gVisor | `1` | `0` |
| UPX | `0` | `1` |
| UPX + gVisor | `1` | `1` |

CI публикует Standard. У опубликованного образа только тег версии проекта и `latest`; остальные варианты собираются локально через build args.

Standard подходит для начала. gVisor нужен функциям, требующим этого build tag. UPX уменьшает размер бинарников; на ARMv5 сжатие отключено. Размер и потребление памяти следует измерять на целевом устройстве.

Цели образа: `linux/amd64`, `linux/arm64`, `linux/arm/v7`, `linux/arm/v5`. MIPS-образа нет. На ARMv5 используется Debian, на остальных архитектурах — Alpine.

Параметры сборки можно изменить в `.env`, затем повторить `docker compose up --build -d`. Для отдельного образа:

```bash
docker buildx build --load --platform linux/amd64 \
  --build-arg PRIZRAK_VERSION=v1.19.34-r2 \
  --build-arg WITH_GVISOR=0 --build-arg UPX=0 \
  -t mihomo-prizrak-docker:local .
```

`PRIZRAK_VERSION` фиксирует чистый тег исходников Prizrak-Core. `APP_VERSION` задаёт версию проекта в OCI-метаданных образа; при публикации CI берёт её из `VERSION` и проверяет совпадение с Git-тегом. Версия ядра и его исходный commit записаны в `/usr/share/prizrak-core/build-info`. Имя `mihomo` оставлено как ссылка на `prizrak-core`.

## MikroTik RouterOS

Нужна модель и версия RouterOS с поддержкой контейнеров, установленный пакет `container` и включённая функция контейнеров. Проверьте архитектуру и доступную RAM; для образа, распаковки и данных используйте внешний накопитель. Подготовка описана в [руководстве MikroTik](https://manual.mikrotik.com/docs/containers/).

Сначала создайте VETH с доступом в интернет и настройте маршрутизацию LAN к нему. Пример ниже предполагает уже настроенный `veth-prizrak` и накопитель `disk1`; он не настраивает LAN, DNS клиентов и firewall.

До первой успешной публикации CI соберите архив на Linux для архитектуры роутера:

```bash
docker buildx build --platform linux/arm64 \
  --build-arg PRIZRAK_VERSION=v1.19.34-r2 \
  --output type=docker,dest=prizrak-arm64.tar .
```

Загрузите архив на накопитель роутера как `disk1/prizrak-arm64.tar`. Для другой архитектуры измените `--platform` и имя файла.

Пример для актуального CLI RouterOS:

```routeros
/container/envs/add list=prizrak key=NETWORK_MODE value=mikrotik
/container/envs/add list=prizrak key=UI_SECRET value="YOUR_SECRET"
/container/envs/add list=prizrak key=SUB1 value="YOUR_SUBSCRIPTION_URL"
/container/envs/add list=prizrak key=DNS_LISTEN value="0.0.0.0:53"
/container/mounts/add list=prizrak-data src=disk1/prizrak-data dst=/etc/mihomo
/container/add file=disk1/prizrak-arm64.tar interface=veth-prizrak root-dir=disk1/prizrak-root mountlists=prizrak-data envlists=prizrak name=prizrak logging=yes start-on-boot=yes
/container/print
```

Дождитесь окончания распаковки и состояния `stopped`, затем выполните `/container/start prizrak`. Имена `envlists` / `mountlists` зависят от версии RouterOS; в старых версиях используются `envlist` / `mounts`. Проверьте параметры своей версии через `?` и [CLI reference](https://manual.mikrotik.com/docs/cli-reference/container/).

Прозрачному режиму нужны доступные ядру контейнера сетевые операции и TUN либо nftables. Их доступность зависит от RouterOS и модели. При `IPTABLES=1` режим MikroTik принудительно выбирает TUN. DNS-порт `53` в примере нужен, если RouterOS направляет DNS в контейнер; стандартный Docker-образ слушает `1053`. Закройте API и прокси от WAN правилами роутера.

После успешной публикации тега `0.1.0` образ будет доступен как `ghcr.io/vrbeeshop/mihomo-prizrak-docker:0.1.0` и `ghcr.io/vrbeeshop/mihomo-prizrak-docker:latest`. Для загрузки с роутера настройте registry `https://ghcr.io` и используйте `remote-image=vrbeeshop/mihomo-prizrak-docker:latest` вместо `file=...`; пакет GHCR должен быть публичным либо нужны учётные данные registry. До публикации используйте архив или собственный registry.

На OpenWrt с Docker применим контейнерный вариант при наличии нужных ресурсов и модулей ядра. Установка Prizrak-Core непосредственно в OpenWrt без Docker — отдельный способ развёртывания, в этот репозиторий не входит.

## Проверки и публикация

```bash
bash scripts/smoke-test.sh mihomo-prizrak-docker:local
```

Скрипт проверяет контейнер и конфигурации без изменения сети хоста. Проверка конфигурации не подтверждает соединение с конкретным сервером. Полный TUN/TPROXY, производительность и работа на модели MikroTik требуют проверки на целевом устройстве.

Для `v1.19.34-r2` локально прошли проверки amd64-образов Standard и gVisor + UPX: запуск без сетевых привилегий, HTTP/SOCKS-запросы, загрузка VLESS/XHTTP и Hysteria2 из URI, конфигурации всех сетевых режимов. Кросс-компиляция ядра прошла для ARM64, ARMv7 и ARMv5; запуск ARM-контейнеров на устройстве ещё не проверен.

GitHub Actions на обычные push в любые ветки и на PR запускает проверки, включая локальную сборку amd64 и smoke-тесты. Публикации образа при этих событиях нет.

Публикация в GHCR запускается только при push числового Git-тега формата `MAJOR.MINOR.PATCH`, например `0.1.0`. Тег должен совпадать с содержимым `VERSION`. После успешных проверок CI собирает Standard для `linux/amd64`, `linux/arm64`, `linux/arm/v7` и `linux/arm/v5` и публикует два тега:

- `ghcr.io/<владелец>/<репозиторий>:0.1.0` — версия проекта;
- `ghcr.io/<владелец>/<репозиторий>:latest` — последний опубликованный релиз.

Теги с хешами коммитов не создаются. Для входа в GHCR используется `GITHUB_TOKEN`; Docker Hub и отдельный registry token не требуются.

Для первого релиза сначала включите проверенные изменения и файл `VERSION` со значением `0.1.0` в коммит и отправьте ветку в GitHub. Затем создайте тег на этом коммите:

```bash
git tag 0.1.0
git push origin 0.1.0
```

Для следующего релиза обновите `VERSION`, закоммитьте изменения и отправьте соответствующий числовой тег. Обновление `PRIZRAK_VERSION` само по себе релиз не запускает.
