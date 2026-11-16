# Prizrak-Core в Docker и на роутере

Форк [mihomo-mikrotik](https://github.com/wiktorbgu/mihomo-mikrotik), переведённый на [Prizrak-Core](https://github.com/legiz-ru/Prizrak-Core). Контейнер собирает ядро из исходников и сохраняет формат конфигурации mihomo, переменные подписок и каталог `/etc/mihomo`.

Prizrak-Core добавляет к mihomo возможности Xray: XHTTP, REALITY с ML-DSA-65, mux.cool, finalmask и mKCP для VLESS. Также доступны протоколы ядра, включая VLESS, Trojan, Hysteria2, TUIC, Shadowsocks и WireGuard. Параметры конкретного сервера должны поддерживаться выбранной версией ядра; см. [официальную документацию](https://core.prizrak.app/ru/).

## Быстрый запуск на домашнем сервере

Выберите один способ запуска для экземпляра: Docker Compose ниже или `docker run` в следующем разделе.

```bash
cp .env.example .env
```

Задайте свой `UI_SECRET` в `.env` и добавьте `SUB1` с HTTP(S)-URL подписки либо `SRV1` со ссылкой узла. Затем:

```bash
docker compose pull
docker compose up -d
docker compose logs -f prizrak
```

Данные сохраняются в `./data`. Без подписок и узлов используется `DIRECT`: контейнер запускается, но трафик идёт напрямую.

| Сервис | Адрес на сервере |
| --- | --- |
| HTTP / SOCKS5 | `127.0.0.1:20170` TCP и UDP |
| API управления | `127.0.0.1:9090` TCP |
| DNS внутри контейнера | `0.0.0.0:1053`, наружу не опубликован |

Веб-панель в образ не включена: при первом запуске ядро скачивает zashboard в `./data/ui` и отдаёт её по адресу `http://127.0.0.1:9090/ui/`. Для загрузки нужен доступ к GitHub. Можно задать `EXTERNAL_UI_URL` с архивом другой совместимой панели либо подключить клиент к API с `UI_SECRET`. В стандартном Compose порты доступны только с самого сервера. Для устройств LAN адрес публикации и правила firewall задаются отдельно.

Проверка HTTP-прокси:

```bash
curl --proxy http://127.0.0.1:20170 https://ipwho.is/
```

Обычный режим не требует `NET_ADMIN` и `/dev/net/tun`; стартовый скрипт не меняет NAT и policy routing. Проксирование применяется к приложениям, в которых указан этот прокси.

## Docker run без Compose

Подготовьте окружение и каталог данных:

```bash
cp .env.example .env
mkdir -p data
```

Замените `UI_SECRET` и добавьте свою подписку в `SUB1` внутри `.env`. Затем запустите контейнер:

```bash
docker run -d --name prizrak --restart unless-stopped --pull always \
  --env-file .env \
  -p 127.0.0.1:20170:20170/tcp \
  -p 127.0.0.1:20170:20170/udp \
  -p 127.0.0.1:9090:9090/tcp \
  --mount type=bind,source="$(pwd)/data",target=/etc/mihomo \
  ghcr.io/vrbeeshop/mihomo-prizrak-docker:latest
docker logs -f prizrak
```

Прокси и панель доступны по тем же адресам, что и в Compose. `Ctrl+C` завершает просмотр логов; остановка и удаление контейнера выполняются отдельно:

```bash
docker stop prizrak
docker rm prizrak
```

Данные остаются в `./data`. После изменения `.env` пересоздайте контейнер той же командой `docker run`. Переменные в `--env-file` применяются при запуске.

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
docker compose -f compose.tun.yaml pull
docker compose -f compose.tun.yaml up -d
docker compose -f compose.tun.yaml logs -f prizrak
```

Используйте `compose.tun.yaml` самостоятельно, без объединения с `compose.yaml`. Для возврата остановите его через `docker compose -f compose.tun.yaml down` и запустите обычный Compose.

TUN сервера сам по себе не делает его шлюзом для LAN. Для перехвата трафика других устройств требуются настройки шлюза, forwarding и firewall. В `tproxy` доступны `TPROXY_INTERFACE` и `TPROXY_PORT` (по умолчанию `15123`); этот режим требует nftables и `NET_ADMIN`. `TUN_AUTO_REDIRECT` по умолчанию выключен.

## Подписки и собственные конфигурации

В `.env` можно задать `SUB1`, `SUB2`, … с HTTP(S)-URL подписок и `SRV1`, `SRV2`, … с поддерживаемыми ядром URI узлов. HTTP(S)-URL в `SRVn` тоже обрабатываются как подписки. Конфигурация выбирается по содержимому ответа:

| Источник | Рабочая конфигурация |
| --- | --- |
| Полный конфиг Mihomo по подписке | Его правила, DNS-политики, группы, ноды и провайдеры становятся основными |
| Подписка со списком нод: URI, Base64, YAML с одним `proxies` или Xray JSON | Ноды подключаются к нашему шаблону с его правилами |
| Отдельные ноды в `SRVn` | Используется наш шаблон с его правилами |
| Явно заданный собственный `CONFIG` | Используется этот файл или шаблон, автоматического выбора полного конфига подписки нет |

У полного конфига подписки заменяются настройки входящих соединений: порты и адреса прослушивания, API, `UI_SECRET`, Zashboard и режим сети берутся из настроек контейнера. Политика DNS остаётся из подписки, а адрес его сервиса задаёт `DNS_LISTEN`. Параметры общего `ipv6`, логирования и поиска процессов также задаёт контейнер. Поэтому TUN и порты телефонного конфига не включаются поверх выбранного `NETWORK_MODE`.

Если полных конфигов несколько, выбирается первый среди `SUBn` по возрастанию номера, затем проверяются HTTP(S)-ссылки в `SRVn`. Правила разных конфигов и дополнительные `SRVn`-ноды в него не объединяются. Если полного конфига нет, все подписки с нодами и отдельные ноды используются нашим шаблоном. В нём локальная сеть идёт напрямую, а сопоставления fake-IP сохраняются между перезапусками.

Полная подписка обновляется целиком с повторным применением настроек контейнера и перезагрузкой конфига через API. `SUBSCRIPTION_INTERVAL` задаёт интервал в секундах; по умолчанию используется `PROVIDER_INTERVAL` (`3600`), `0` отключает фоновое обновление. Таймаут загрузки задаёт `SUBSCRIPTION_TIMEOUT` (`30` секунд). Для запроса используются постоянный HWID, заголовки `PROVIDER_HEADER` и стандартный User-Agent `clash.meta`, который можно переопределить своим заголовком.

Для первого запуска нужна доступная подписка. После успешной загрузки сохраняется рабочая копия, привязанная к её URL; при временной недоступности сервера она позволяет запуститься с прежним конфигом. Сбой загрузки или проверки оставляет прежний конфиг. При ошибке API восстанавливается прежний файл и выполняется попытка повторного применения; если API недоступен и откат не подтверждён, это отмечается в логах. В режиме списка нод обновлением провайдеров по-прежнему управляет ядро.

Для специфичных параметров Prizrak-Core используйте YAML: преобразователь ссылок провайдера должен уметь передавать эти параметры.

Каталог `./data` соответствует `/etc/mihomo`:

| Путь | Назначение |
| --- | --- |
| `default_config.yaml` | Рабочий конфиг из подписки или нашего шаблона; ручные изменения перезаписываются при запуске и обновлении |
| `template/default_config.yaml` | Поставляемый шаблон, обновляется из образа с резервной копией `default_config_old.yaml` |
| `config.yaml` | Готовая собственная конфигурация при `CONFIG=config.yaml`; без `envsubst` |
| `template/custom.yaml` | Собственный шаблон с переменными окружения при `CONFIG=custom.yaml` |
| `subscriptions/` | Служебный шаблон, активный источник и кэш подписок; копии в `cache/` адресуются по имени переменной и SHA-256 URL |
| `awg/*.conf` | Конфигурации WireGuard / AmneziaWG, преобразуемые в провайдер |
| `user_sh/*.sh` | Пользовательские скрипты, выполняемые при обычном старте |
| `.hwid` | Постоянный идентификатор для подписок с привязкой к устройству |

Чтобы задать собственные правила маршрутизации или группы независимо от подписки, используйте собственный `CONFIG`. Он имеет приоритет над автоматическим выбором конфига из URL. В готовом YAML вы сами задаёте listeners, DNS, API и секрет: переменные стандартного шаблона его не изменяют.

Полезные настройки стандартного шаблона: `LOG_LEVEL`, `IPV6`, `DNS`, `DNS_BOOTSTRAP`, `DNS_LISTEN`, `MIXED_PORT`, `UI_PORT`, `UI_SECRET`. Несколько DNS-серверов разделяются `|`. У провайдеров есть общий и индивидуальный `PROVIDER_HEADER`, `PROVIDER_FILTER`, `PROVIDER_EXCLUDE_FILTER`; индивидуальные имена заканчиваются, например, на `_SUB1`.

Фильтры и `PROVIDER_OVERRIDE_*` применяются к провайдерам в режиме списка нод. Они не перестраивают группы и ноды полного конфига подписки; его содержимое задаёт сама подписка. Заголовки загрузки и HWID используются в обоих режимах.

Проверка конфигурации без запуска перехвата:

```bash
docker compose run --rm prizrak --render-config
docker compose run --rm prizrak -t -d /etc/mihomo -f /etc/mihomo/default_config.yaml
```

`--render-config` создаёт конфигурацию без изменения сети, выполнения `user_sh` и запуска фонового обновления. При заданных подписках команда загружает и адаптирует их конфиг либо использует сохранённую рабочую копию. Аргументы ядра, включая `-v`, `-h` и `-t`, передаются напрямую; при таком запуске генерации конфигурации нет.

## Сборки и архитектуры

Для самостоятельной сборки доступны варианты: обычный (Standard), gVisor, UPX, UPX + gVisor.

Standard подходит для начала. gVisor нужен функциям, требующим этого build tag. UPX уменьшает размер бинарников; на ARMv5 сжатие отключено. Размер и потребление памяти следует измерять на целевом устройстве.

Цели образа: `linux/amd64`, `linux/arm64`, `linux/arm/v7`, `linux/arm/v5`. MIPS-образа нет. На ARMv5 используется Debian, на остальных архитектурах — Alpine.

Для самостоятельной сборки через Compose задайте `PRIZRAK_IMAGE=mihomo-prizrak-docker:local` и параметры `WITH_GVISOR` / `UPX` в `.env`, затем выполните `docker compose up --build -d`. Для отдельного локального образа:

```bash
docker buildx build --load --platform linux/amd64 \
  --build-arg WITH_GVISOR=0 --build-arg UPX=0 \
  -t mihomo-prizrak-docker:local .
```

При каждой сборке автоматически выбирается последний релиз Prizrak-Core. Фактическая версия ядра и его исходный commit записаны в `/usr/share/prizrak-core/build-info` и описании GitHub Release. `APP_VERSION` задаёт версию проекта в OCI-метаданных образа; при публикации CI берёт её из `VERSION`. Имя `mihomo` оставлено как ссылка на `prizrak-core`.

## MikroTik RouterOS

Нужна модель и версия RouterOS с поддержкой контейнеров, установленный пакет `container` и включённая функция контейнеров. Проверьте архитектуру и доступную RAM; для образа, распаковки и данных используйте внешний накопитель. Подготовка описана в [руководстве MikroTik](https://manual.mikrotik.com/docs/containers/).

Сначала создайте VETH с доступом в интернет и настройте маршрутизацию LAN к нему. Пример ниже предполагает уже настроенный `veth-prizrak` и накопитель `disk1`; он не настраивает LAN, DNS клиентов и firewall.

Пример для актуального CLI RouterOS:

```routeros
/container/config/set registry-url=https://ghcr.io
/container/envs/add list=prizrak key=NETWORK_MODE value=mikrotik
/container/envs/add list=prizrak key=UI_SECRET value="YOUR_SECRET"
/container/envs/add list=prizrak key=SUB1 value="YOUR_SUBSCRIPTION_URL"
/container/envs/add list=prizrak key=DNS_LISTEN value="0.0.0.0:53"
/container/mounts/add list=prizrak-data src=disk1/prizrak-data dst=/etc/mihomo
/container/add remote-image=vrbeeshop/mihomo-prizrak-docker:latest interface=veth-prizrak root-dir=disk1/prizrak-root mountlists=prizrak-data envlists=prizrak name=prizrak logging=yes start-on-boot=yes
/container/print
```

Дождитесь окончания распаковки и состояния `stopped`, затем выполните `/container/start prizrak`. Имена `envlists` / `mountlists` зависят от версии RouterOS; в старых версиях используются `envlist` / `mounts`. Проверьте параметры своей версии через `?` и [CLI reference](https://manual.mikrotik.com/docs/cli-reference/container/).

Прозрачному режиму нужны доступные ядру контейнера сетевые операции и TUN либо nftables. Их доступность зависит от RouterOS и модели. При `IPTABLES=1` режим MikroTik принудительно выбирает TUN. DNS-порт `53` в примере нужен, если RouterOS направляет DNS в контейнер; стандартный Docker-образ слушает `1053`. Закройте API и прокси от WAN правилами роутера.

Для импорта образа архивом загрузите нужную архитектуру на Linux и сохраните её в tar:

```bash
docker pull --platform linux/arm64 ghcr.io/vrbeeshop/mihomo-prizrak-docker:latest
docker save --output prizrak-arm64.tar ghcr.io/vrbeeshop/mihomo-prizrak-docker:latest
```

Скопируйте архив на накопитель роутера и используйте `file=disk1/prizrak-arm64.tar` вместо `remote-image=...`. Для другой архитектуры измените `--platform` и имя файла.

На OpenWrt с Docker применим контейнерный вариант при наличии нужных ресурсов и модулей ядра.
