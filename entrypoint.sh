#!/bin/bash
set -e

# Explicit CLI arguments are passed to the core without preparing a container.
# This also makes `-v`, `-h`, and `-t -f ...` usable without network privileges.
RENDER_ONLY=0
if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 1 ] && [ "$1" = "--render-config" ]; then
        RENDER_ONLY=1
    else
        exec prizrak-core "$@"
    fi
fi

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

export WORKDIR="${WORKDIR:-/etc/mihomo}"
export CONFIG="${CONFIG:-default_config.yaml}"
export NETWORK_MODE="${NETWORK_MODE:-proxy}"
export EXTERNAL_UI_PATH="${EXTERNAL_UI_PATH:-ui}"
export LOG_LEVEL="${LOG_LEVEL:-info}"
export UI_SECRET="${UI_SECRET:-}"
export MIXED_BIND_ADDRESS="${MIXED_BIND_ADDRESS:-0.0.0.0}"
TPROXY_PORT="${TPROXY_PORT:-15123}"
TPROXY_MARK=0x123
TPROXY_TABLE=100

case "$NETWORK_MODE" in
    proxy|tun|tproxy|mikrotik) ;;
    *) fail "NETWORK_MODE must be proxy, tun, tproxy, or mikrotik (got '$NETWORK_MODE')" ;;
esac

# Detection is read-only, including during --render-config.
NFT_CORE=0
if [ "$NETWORK_MODE" != "proxy" ] && [ "${IPTABLES:-0}" != "1" ] && { grep -q '^nf_tables ' /proc/modules 2>/dev/null || { [ "$RENDER_ONLY" = 0 ] && nft list tables >/dev/null 2>&1; }; }; then
    NFT_CORE=1
fi
export DISABLE_NFTABLES=$((1 - NFT_CORE))

FIRST_IFACE=""
OTHER_IFACES=""
GATEWAY=""
LOCAL_IPS=""
if [ "$NETWORK_MODE" = "mikrotik" ] || [ "$NETWORK_MODE" = "tproxy" ]; then
    FIRST_IFACE=$(ip -o link show | awk -F': ' '/link\/ether/ {print $2; exit}' | cut -d@ -f1)
    FIRST_IFACE="${TPROXY_INTERFACE:-$FIRST_IFACE}"
    OTHER_IFACES=$(ip -o link show | awk -F': ' '/link\/ether/ {print $2}' | cut -d@ -f1)
    GATEWAY=$(ip route | awk -v iface="$FIRST_IFACE" '$1=="default" && $0~iface {print $3; exit}')
    LOCAL_IPS=$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}' | paste -sd, -)
    if [ "$RENDER_ONLY" = 0 ] && [ -z "$FIRST_IFACE" ]; then
      fail "No Ethernet interface found; set TPROXY_INTERFACE explicitly"
    fi
fi

setup_mikrotik_network() {
    # RouterOS-specific changes are confined to an explicitly selected mode.
    if [ "$NFT_CORE" -eq 1 ]; then
        nft delete table ip prizrak_nat 2>/dev/null || true
        nft add table ip prizrak_nat
        nft 'add chain ip prizrak_nat postrouting { type nat hook postrouting priority srcnat; }'
        nft 'add rule ip prizrak_nat postrouting meta oiftype ether ip daddr != { 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 } masquerade'
    fi

    # Remove the early main/default rules introduced by RouterOS 7.22.
    ip rule | awk '
    /lookup main/ && $1+0 < 32766 {gsub(":","",$1); print $1}
    /lookup default/ && $1+0 < 32767 {gsub(":","",$1); print $1}
    ' | while read -r prio; do
        ip rule del priority "$prio"
    done
    ip rule | grep -q "lookup main" || ip rule add lookup main priority 32766
    ip rule | grep -q "lookup default" || ip rule add lookup default priority 32767
}

if [ "$NETWORK_MODE" = "mikrotik" ] && [ "$RENDER_ONLY" = 0 ]; then
    setup_mikrotik_network
fi

#
AWG_DIR="$WORKDIR/awg"
TEMPLATE_DIR="$WORKDIR/template"
USER_SH_DIR="$WORKDIR/user_sh"
mkdir -p "$AWG_DIR" "$TEMPLATE_DIR" "$USER_SH_DIR"
DEFAULT_CONFIG_FILE="${DEFAULT_CONFIG_FILE:-/etc/mihomo_preset/template/default_config.yaml}"
TEMPLATE_FILE="$TEMPLATE_DIR/$CONFIG"
BACKUP_PATH="$TEMPLATE_DIR/default_config_old.yaml"

# если не указано имя кастомного конфига, испольузем и актуализируем default
if [ "$CONFIG" = "default_config.yaml" ]; then
  if [ -f "$TEMPLATE_FILE" ]; then
    if ! diff -q "$DEFAULT_CONFIG_FILE" "$TEMPLATE_FILE" >/dev/null; then
      mv "$TEMPLATE_FILE" "$BACKUP_PATH"
      cp "$DEFAULT_CONFIG_FILE" "$TEMPLATE_FILE"
    fi
  else
    cp "$DEFAULT_CONFIG_FILE" "$TEMPLATE_FILE"
  fi
  CONFIG_FILE=$TEMPLATE_FILE
else
  if [ -f "$TEMPLATE_FILE" ]; then
    # есть заданный шаблон — используем его
    CONFIG_FILE="$TEMPLATE_FILE"
  elif [ -f "$WORKDIR/$CONFIG" ]; then
    # шаблона нет, но есть кастомный конфиг
    CONFIG_FILE="$WORKDIR/$CONFIG"
    ENVSUBST=0
  else
    # нет ни шаблона, ни кастомного конфига
    log "ERROR: Config not found! Checked: $TEMPLATE_FILE and $WORKDIR/$CONFIG. Check container mounts/volume paths."
    exit 1
  fi
fi    

# смена веб панели при замене ссылки на её загрузку
UI_URL_CHECK="$WORKDIR/.ui_url"
LAST_UI_URL=$(cat "$UI_URL_CHECK" 2>/dev/null || true)
if [ "$RENDER_ONLY" = 0 ] && [[ "$EXTERNAL_UI_URL" != "$LAST_UI_URL" ]]; then
  if [[ "$EXTERNAL_UI_PATH" = /* || "$EXTERNAL_UI_PATH" = . || "$EXTERNAL_UI_PATH" = .. || "/$EXTERNAL_UI_PATH/" = */../* ]]; then
    fail "EXTERNAL_UI_PATH must be a relative directory inside WORKDIR"
  fi
  rm -rf -- "$WORKDIR/$EXTERNAL_UI_PATH"
  echo "$EXTERNAL_UI_URL" > "$UI_URL_CHECK"
fi

# генерируем hwid для серверов и подписок с ограничениями по устройствам
HWID_STORE="$WORKDIR/.hwid"
if [ ! -f "$HWID_STORE" ]; then
  cat /proc/sys/kernel/random/uuid | tr -d '-' > "$HWID_STORE"
fi
HWID="${HWID:-$(cat "$HWID_STORE")}"

yaml_quote() {
  sed 's/\\/\\\\/g; s/"/\\"/g; s/.*/"&"/'
}

format_yaml_list() {
    local value="$1"
    # Количество пробелов перед элементом списка, по умолчанию 2
    local indent="${2:-2}"
    # символ разделителя
    local separator="${3:-|}"
    local quote="${4:-0}"
    local expand="${5:-1}"

    # Раскрываем вложенные ENV-переменные, если разрешено
    if [ "$expand" = "1" ]; then
        # Expand only documented DNS references once; shell code stays literal.
        value=$(printf '%s' "$value" | envsubst '${DNS} ${DNS_BOOTSTRAP}')
    fi

    printf '%s\n' "$value" |
        tr "$separator" '\n' |
        while IFS= read -r item; do
            item=$(printf '%s' "$item" |
                sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

            [ -n "$item" ] || continue

            # При необходимости экранируем и заключаем в YAML-кавычки
            if [ "$quote" = "1" ]; then
                item=$(printf '%s' "$item" | yaml_quote)
            fi

            printf '\n%*s- %s' "$indent" '' "$item"
        done
}

DNS_NAMESERVER=$(format_yaml_list "${DNS_NAMESERVER:-}" 4 '|' 1)
DNS_DEFAULT_NAMESERVER=$(format_yaml_list "${DNS_DEFAULT_NAMESERVER:-}" 4 '|' 1)
DNS_PROXY_SERVER_NAMESERVER=$(format_yaml_list "${DNS_PROXY_SERVER_NAMESERVER:-}" 4 '|' 1)
DNS_FAKE_IP_FILTER=$(format_yaml_list "${DNS_FAKE_IP_FILTER:-}" 4 '|' 1 0)

export DNS_NAMESERVER
export DNS_DEFAULT_NAMESERVER
export DNS_PROXY_SERVER_NAMESERVER
export DNS_FAKE_IP_FILTER

###
parse_awg_config() {
  local config_file="$1"
  local awg_name="${2:-$(basename "$config_file" .conf)}"

read_cfg() {
  local key="$1"
  grep -iE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*" "$config_file" 2>/dev/null | \
    tail -n1 | \
    sed -E 's/^[[:space:]]*[^=]*=[[:space:]]*//I' | \
    tr -d '\r\n' | \
    sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

  local private_key=$(read_cfg "PrivateKey")
  local address=$(read_cfg "Address")
  local dns=$(read_cfg "DNS")
  local mtu=$(read_cfg "MTU")
  local keepalive=$(read_cfg "PersistentKeepalive")
  # 3.0 разрешает диапазон ("22-30"), но mihomo держит persistent-keepalive в int и на диапазоне не распарсит конфиг вовсе. 
  # Берём нижнюю границу: keepalive чаще — лишний трафик, но NAT точно останется живым.
  case "$keepalive" in
    *-*)
      log "AWG $awg_name: PersistentKeepalive range '$keepalive' -> ${keepalive%%-*} (mihomo accepts a single value)" >&2
      keepalive="${keepalive%%-*}"
      ;;
  esac
  local workers=$(read_cfg "Workers")

  local jc=$(read_cfg "Jc");         local jmin=$(read_cfg "Jmin");     local jmax=$(read_cfg "Jmax")
  local s1=$(read_cfg "S1");         local s2=$(read_cfg "S2")
  local s3=$(read_cfg "S3");         local s4=$(read_cfg "S4")
  local h1=$(read_cfg "H1");         local h2=$(read_cfg "H2");         local h3=$(read_cfg "H3");         local h4=$(read_cfg "H4")
  local i1=$(read_cfg "I1");         local i2=$(read_cfg "I2");         local i3=$(read_cfg "I3")
  local i4=$(read_cfg "I4");         local i5=$(read_cfg "I5")
  local j1=$(read_cfg "J1");         local j2=$(read_cfg "J2");         local j3=$(read_cfg "J3")
  local itime=$(read_cfg "ITime")

  # AmneziaWG 3.0. HeaderProtectionKey и ContentPaddingAddition должны совпадать с сервером, тайминги — чисто клиентские. 
  # Все значения, кроме ключа, задаются диапазоном "a-b" либо одним числом.
  local hp_key=$(read_cfg "HeaderProtectionKey")
  local content_padding=$(read_cfg "ContentPaddingAddition")
  local rekey_after=$(read_cfg "RekeyAfterTime")
  local rekey_timeout=$(read_cfg "RekeyTimeout")
  local reject_after=$(read_cfg "RejectAfterTime")
  local keepalive_timeout=$(read_cfg "KeepaliveTimeout")
  local max_handshakes=$(read_cfg "MaxHandshakeAttempts")
  # AmneziaWG 3.1 boolean options.
  local random_trailers=$(read_cfg "RandomTrailers")
  local disable_cookies=$(read_cfg "DisableCookies")
  case "$(printf '%s' "$random_trailers" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) random_trailers=true ;;
    0|false|no|off) random_trailers=false ;;
    *) random_trailers="" ;;
  esac
  case "$(printf '%s' "$disable_cookies" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) disable_cookies=true ;;
    0|false|no|off) disable_cookies=false ;;
    *) disable_cookies="" ;;
  esac
  # Ручное переопределение — на случай, когда 3.0 нужна без единого v3-параметра
  local awg_version=$(read_cfg "AwgVersion")

  local public_key=$(read_cfg "PublicKey")
  local psk=$(read_cfg "PresharedKey")
  local endpoint=$(read_cfg "Endpoint")

  local ip_v4=""
  local ip_v6=""
  if [ -n "$address" ]; then
    OLDIFS=$IFS
    IFS=','
    for addr in $address; do
      addr=$(echo "$addr" | sed 's/[[:space:]]//g')
      if echo "$addr" | grep -q ':'; then
        [ -n "$ip_v6" ] && ip_v6="$ip_v6,"
        ip_v6="${ip_v6}${addr%%/*}"
      else
        [ -n "$ip_v4" ] && ip_v4="$ip_v4,"
        ip_v4="${ip_v4}${addr%%/*}"
      fi
    done
    IFS=$OLDIFS
  fi

  local server=""
  local port=""
  if [ -n "$endpoint" ]; then
    endpoint=$(echo "$endpoint" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if echo "$endpoint" | grep -q '\['; then
      server=$(echo "$endpoint" | sed -E 's@^\[([^]]+)\]:(.*)$@\1@')
      port=$(echo "$endpoint" | sed -E 's@^\[([^]]+)\]:(.*)$@\2@')
    else
      server=$(echo "$endpoint" | cut -d':' -f1)
      port=$(echo "$endpoint" | cut -d':' -f2-)
    fi
  fi

  local allowed_ips_raw=$(read_cfg "AllowedIPs")
  if [ -n "$allowed_ips_raw" ]; then
    allowed_ips_yaml=$(echo "$allowed_ips_raw" | tr ',' '\n' | \
      sed -E 's/^[[:space:]]*([0-9a-fA-F\.:\/-]+)[[:space:]]*$/\1/' | \
      grep -v '^$' | grep -E '^[0-9a-fA-F\.:]+/[0-9]+$' | \
      sed 's/.*/"&"/' | paste -sd, -)
    [ -z "$allowed_ips_yaml" ] && allowed_ips_yaml='"0.0.0.0/0", "::/0"'
  else
    allowed_ips_yaml='"0.0.0.0/0", "::/0"'
  fi

  echo "  - name: \"$awg_name\""
  echo "    type: wireguard"
  [ -n "$private_key" ] && echo "    private-key: $private_key"
  [ -n "$server" ] && echo "    server: $server"
  [ -n "$port" ] && echo "    port: $port"
  [ -n "$ip_v4" ] && echo "    ip: $ip_v4"
  [ -n "$ip_v6" ] && echo "    ipv6: $ip_v6"
  [ -n "$public_key" ] && echo "    public-key: $public_key"
  [ -n "$psk" ] && echo "    pre-shared-key: $psk"
  [ -n "$keepalive" ] && echo "    persistent-keepalive: $keepalive"
  [ -n "$mtu" ] && echo "    mtu: $mtu"
  local dialer_proxy_raw=$(read_cfg "DialerProxy")
  if [ -n "$dialer_proxy_raw" ]; then
    local dialer_proxy_clean=$(echo "$dialer_proxy_raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^["'\'']|["'\'']$//g')
    if [ -n "$dialer_proxy_clean" ]; then
      echo "    dialer-proxy: \"$dialer_proxy_clean\""
    fi
  fi
  [ -n "$workers" ] && echo "    workers: $workers"

  local reserved_raw=$(read_cfg "Reserved")
  if [ -n "$reserved_raw" ]; then
    local reserved_clean=$(echo "$reserved_raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^["'\'']|["'\'']$//g')
    if [ -n "$reserved_clean" ]; then
      if echo "$reserved_clean" | grep -q ','; then
        echo "    reserved: [$reserved_clean]"
      else
        echo "    reserved: \"$reserved_clean\""
      fi
    fi
  fi

  echo "    allowed-ips: [$allowed_ips_yaml]"
  echo "    udp: true"
  echo "    ip-stack:"
  echo "      mode: auto"
  echo "      congestion-controller: bbr3"
  local dns_raw=$(read_cfg "DNS")
  if [ -n "$dns_raw" ] && ! echo "$dns_raw" | grep -q '\$'; then
    local dns_list=$(echo "$dns_raw" | tr ',' '\n' | \
      sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | \
      grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)
    echo "    dns: [$dns_list]"
  fi
  local remote_resolve_raw=$(read_cfg "RemoteDnsResolve")
  if [ -n "$remote_resolve_raw" ]; then
    case "$(echo "$remote_resolve_raw" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes|on)
        echo "    remote-dns-resolve: true"
        ;;
      0|false|no|off)
        echo "    remote-dns-resolve: false"
        ;;
    esac
  fi

  # Версия протокола. mihomo поднимает v3-реализацию только при version: 3;
  # при любом другом значении работает legacy — она же обслуживает 1.5 и 2.0.
  local awg3=0
  for v in "$hp_key" "$content_padding" "$rekey_after" "$rekey_timeout" "$reject_after" "$keepalive_timeout" "$max_handshakes" "$random_trailers" "$disable_cookies"; do
    [ -n "$v" ] && awg3=1
  done
  case "$awg_version" in
    3|3.*) awg3=1 ;;
    "") ;;
    *) awg3=0 ;;
  esac

  if [ "$awg3" -eq 1 ]; then
    # J1-J3 и ITime были только в 1.5 и вырезаны из 3.0. 
    # UAPI ядра отвергает неизвестный ключ целиком — с ними proxy просто не поднимется.
    if [ -n "$j1$j2$j3$itime" ]; then
      log "AWG $awg_name: dropping v1.5-only J1-J3/ITime, AmneziaWG 3.0 removed them" >&2
      j1=""; j2=""; j3=""; itime=""
    fi
    # Header protection шифрует заголовки, беря S1-S4 как nonce, поэтому 
    # ядро требует каждое из них >= 12 (HeaderCipherNonceSize) и иначе падает.
    if [ -n "$hp_key" ]; then
      for v in s1 s2 s3 s4; do
        eval val=\$$v
        case "$val" in
          ''|*[!0-9]*) val=0 ;;
        esac
        if [ "$val" -lt 12 ]; then
          log "AWG $awg_name: WARNING $v=$val, HeaderProtectionKey requires >= 12 — the peer will refuse to start" >&2
        fi
      done
    fi
  fi

  local awg_params="jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3 itime"
  awg_params="$awg_params hp_key content_padding rekey_after rekey_timeout reject_after keepalive_timeout max_handshakes random_trailers disable_cookies"
  local has_awg_param=0
  for v in i1 i2 i3 i4 i5; do
    eval val=\$$v
    case "$val" in
      \<*\>) ;;
      *) eval "$v=" ;;
    esac
  done
  for v in $awg_params; do
    eval val=\$$v
    [ -n "$val" ] && has_awg_param=1
  done

  if [ "$has_awg_param" -eq 1 ]; then
    echo "    amnezia-wg-option:"
    [ -n "$jc" ]     && echo "      jc: $jc"
    [ -n "$jmin" ]   && echo "      jmin: $jmin"
    [ -n "$jmax" ]   && echo "      jmax: $jmax"
    [ -n "$s1" ]     && echo "      s1: $s1"
    [ -n "$s2" ]     && echo "      s2: $s2"
    [ -n "$s3" ]     && echo "      s3: $s3"
    [ -n "$s4" ]     && echo "      s4: $s4"
    [ -n "$h1" ]     && echo "      h1: $h1"
    [ -n "$h2" ]     && echo "      h2: $h2"
    [ -n "$h3" ]     && echo "      h3: $h3"
    [ -n "$h4" ]     && echo "      h4: $h4"
    [ -n "$i1" ]     && printf '      i1: %s\n' "$(printf '%s' "$i1" | yaml_quote)"
    [ -n "$i2" ]     && printf '      i2: %s\n' "$(printf '%s' "$i2" | yaml_quote)"
    [ -n "$i3" ]     && printf '      i3: %s\n' "$(printf '%s' "$i3" | yaml_quote)"
    [ -n "$i4" ]     && printf '      i4: %s\n' "$(printf '%s' "$i4" | yaml_quote)"
    [ -n "$i5" ]     && printf '      i5: %s\n' "$(printf '%s' "$i5" | yaml_quote)"
    [ -n "$j1" ]     && echo "      j1: $j1"
    [ -n "$j2" ]     && echo "      j2: $j2"
    [ -n "$j3" ]     && echo "      j3: $j3"
    [ -n "$itime" ]  && echo "      itime: $itime"
    if [ "$awg3" -eq 1 ]; then
      echo "      version: 3"
      # v3-поля в mihomo объявлены строками (значением может быть диапазон), 
      # поэтому кавычим: иначе YAML отдал бы 22-30 строкой, а 30 — числом.
      [ -n "$hp_key" ]            && printf '      header-protection-key: %s
'    "$(printf '%s' "$hp_key" | yaml_quote)"
      [ -n "$content_padding" ]   && printf '      content-padding-addition: %s
' "$(printf '%s' "$content_padding" | yaml_quote)"
      [ -n "$rekey_after" ]       && printf '      rekey-after-time: %s
'         "$(printf '%s' "$rekey_after" | yaml_quote)"
      [ -n "$rekey_timeout" ]     && printf '      rekey-timeout: %s
'            "$(printf '%s' "$rekey_timeout" | yaml_quote)"
      [ -n "$reject_after" ]      && printf '      reject-after-time: %s
'        "$(printf '%s' "$reject_after" | yaml_quote)"
      [ -n "$keepalive_timeout" ] && printf '      keepalive-timeout: %s
'        "$(printf '%s' "$keepalive_timeout" | yaml_quote)"
      [ -n "$max_handshakes" ]    && printf '      max-handshake-attempts: %s
'   "$(printf '%s' "$max_handshakes" | yaml_quote)"
      [ -n "$random_trailers" ]   && echo "      random-trailers: $random_trailers"
      [ -n "$disable_cookies" ]   && echo "      disable-cookies: $disable_cookies"
    fi
  fi
  echo ""
}

PROVIDERS_BLOCK=""
PROVIDERS_LIST=""

set_default_var() {
    local name="$1"
    local var="$2"
    local value

    value="$(printenv "${var}_${name}" || true)"
    [ -z "$value" ] && value="$(printenv "$var" || true)"

    printf '%s' "$value"
}

add_provider() {
    local name="$1"
    local type="$2"        # file / http
    local source="$3"      # path / url

    # default
    local source_key="path"
    local sub_params=""

    # параметры только для http-провайдеров
    if [[ "$type" == "http" ]]; then
        source_key="url"
        local filter="$(set_default_var "$name" "PROVIDER_FILTER")"
        local exclude_filter="$(set_default_var "$name" "PROVIDER_EXCLUDE_FILTER")"
        local exclude_type="$(set_default_var "$name" "PROVIDER_EXCLUDE_TYPE")"
        local provider_interval="$(set_default_var "$name" "PROVIDER_INTERVAL")"
        local headers_raw="$(set_default_var "$name" "PROVIDER_HEADER")"

        local custom_headers=""
        if [ -n "$headers_raw" ]; then
            headers_raw=$(printf '%s' "$headers_raw" | tr '#' '|')
            OLDIFS=$IFS; IFS='|'
            for pair in $headers_raw; do
                [ -z "$pair" ] && continue
                case "$pair" in
                    *=*) h_key="${pair%%=*}"; h_val="${pair#*=}" ;;
                    *:*) h_key="${pair%%:*}"; h_val="${pair#*:}" ;;
                    *) continue ;;
                esac
                # Очищаем пробелы по краям (так что можно писать с пробелами вокруг |)
                h_key=$(printf '%s' "$h_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                h_val=$(printf '%s' "$h_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//; s/"/\\"/g')
                [ -n "$h_key" ] && [ -n "$h_val" ] && custom_headers="${custom_headers}
      ${h_key}:
      - \"${h_val}\""
            done
            IFS=$OLDIFS
        fi

        # Добавляем системный HWID только если пользователь не передал свой x-hwid
        local hwid_header=""
        if ! echo "$headers_raw" | grep -qi "x-hwid"; then
            hwid_header="
      x-hwid:
      - $HWID"
        fi

        sub_params="
    interval: ${provider_interval}
    header:${hwid_header}${custom_headers}"

        [ -n "$filter" ] && sub_params="${sub_params}"$'\n'"    filter: \"${filter}\""
        [ -n "$exclude_filter" ] && sub_params="${sub_params}"$'\n'"    exclude-filter: \"${exclude_filter}\""
        [ -n "$exclude_type" ] && sub_params="${sub_params}"$'\n'"    exclude-type: \"${exclude_type}\""
    fi

    # индивидуальный override для провайдера
    local override=""
    local value
    local param
    local var

    for param in tfo mptcp udp udp-over-tcp down up skip-cert-verify name-cert-verify dialer-proxy additional-prefix additional-suffix; do
        var="PROVIDER_$(printf '%s' "$param" | tr '[:lower:]-' '[:upper:]_')_${name}"
        value="$(printenv "$var" || true)"
        [ -n "$value" ] || continue

        case "$param" in
            # boolean параметры без кавычек
            tfo|mptcp|udp|udp-over-tcp|skip-cert-verify)
                override="${override}"$'\n'"      ${param}: ${value}" ;;
            *)
                override="${override}"$'\n'"      ${param}: \"${value}\"" ;;
        esac
    done

    # override-expr (разделитель #, поддержка общего и индивидуального ENV)
    local override_expr_raw
    override_expr_raw="$(set_default_var "$name" "PROVIDER_OVERRIDE_EXPR")"

    if [ -n "$override_expr_raw" ]; then
        local override_expr_yaml
        override_expr_yaml="$(format_yaml_list "$override_expr_raw" 8 '#' 1 0)"

        if [ -n "$override_expr_yaml" ]; then
            override="${override}"$'\n'"      override-expr:${override_expr_yaml}"
        fi
    fi

    [ -n "$override" ] && sub_params="${sub_params}"$'\n'"    override:"$override""

    local health_check_enable="$(set_default_var "$name" "HEALTH_CHECK_ENABLE")"
    local health_check_url="$(set_default_var "$name" "HEALTH_CHECK_URL")"
    local health_check_interval="$(set_default_var "$name" "HEALTH_CHECK_INTERVAL")"
    local health_check_timeout="$(set_default_var "$name" "HEALTH_CHECK_TIMEOUT")"
    local health_check_lazy="$(set_default_var "$name" "HEALTH_CHECK_LAZY")"
    local health_check_expected_status="$(set_default_var "$name" "HEALTH_CHECK_EXPECTED_STATUS")"

    PROVIDERS_BLOCK="${PROVIDERS_BLOCK}  ${name}:
    type: ${type}
    ${source_key}: \"${source}\"${sub_params}
    health-check:
      enable: ${health_check_enable}
      url: ${health_check_url}
      interval: ${health_check_interval}
      timeout: ${health_check_timeout}
      lazy: ${health_check_lazy}
      expected-status: ${health_check_expected_status}
"

    PROVIDERS_LIST="${PROVIDERS_LIST}      - ${name}"$'\n'
}


### SRV
srv_file="$WORKDIR/srv.yaml"
srv_file_has_content=0
if env | grep -qE '^SRV[0-9]'; then
    > "$srv_file"
    while IFS='=' read -r name value; do
        case "$name" in
            SRV[0-9]*)
                [ -n "$value" ] || continue
                # HTTP(S) subscriptions use the core downloader; node URIs
                # are read by its native parser through a local file provider.
                srv_scheme=$(printf '%s' "$value" | sed 's/:.*//' | tr '[:upper:]' '[:lower:]')
                case "$srv_scheme" in
                    http|https)
                        add_provider "$name" "http" "$value"
                        ;;
                    *)
                        # а иначе обрабатываем как обычную uri ссылку прокси
                        echo "#== $name ==" >> "$srv_file"
                        printf "%s\n" "$value" >> "$srv_file"
                        srv_file_has_content=1
                        ;;
                esac
                ;;
        esac
    done <<EOF
$(env)
EOF

    # Если были обычные (не URL подписок) SRV-записи — подключаем их как file provider
    if [ "$srv_file_has_content" -eq 1 ]; then
        add_provider "SRV" "file" "$srv_file"
    fi
fi

### AWG
awg_file="$WORKDIR/awg.yaml"
if find "$AWG_DIR" -name "*.conf" -print -quit 2>/dev/null | grep -q .; then
    echo "proxies:" > "$awg_file"
    find "$AWG_DIR" -name "*.conf" | while read -r conf; do
        parse_awg_config "$conf"
    done >> "$awg_file"
    add_provider "AWG" "file" "$awg_file"
fi

### SUB
while IFS='=' read -r name value; do
    case "$name" in
        SUB[0-9]*)
            [ -n "$value" ] || continue
            add_provider "$name" "http" "$value"
            ;;
    esac
done <<EOF
$(env)
EOF

### VETH
if [ "$NETWORK_MODE" = "mikrotik" ] && [ -n "$OTHER_IFACES" ]; then
  # Для дополнительных VETH используем модель multi-WAN Mihomo:
  # отдельная таблица маршрутизации + fwmark, который выставляет сам direct proxy.
  # Это корректно работает для UDP при interface-name.
  TABLE_BASE=201
  i=0
  veth_file="$WORKDIR/veth.yaml"
  IFACE_COUNT=$(echo "$OTHER_IFACES" | wc -w)

  if [ "$IFACE_COUNT" -gt 1 ]; then
    echo "proxies:" > "$veth_file"
    for IFACE in $OTHER_IFACES; do
      [ "$IFACE" = "$FIRST_IFACE" ] && continue

      SRC_CIDR=$(ip route show dev "$IFACE" scope link | awk 'NR==1 {print $1}')
      SRC_IP=$(ip -o -4 addr show dev "$IFACE" | awk 'NR==1 {
          split($4,a,"/")
          print a[1]
      }')

      [ -z "$SRC_CIDR" ] && continue
      [ -z "$SRC_IP" ] && continue

      TABLE=$((TABLE_BASE + i))
      MARK=$TABLE
      RULE_PREF=$((150 + i))
      MARK_HEX=$(printf '0x%x' "$MARK")

      cat >> "$veth_file" <<EOF
- name: $IFACE
  type: direct
  ip-version: $IP_VERSION
  interface-name: $IFACE
  routing-mark: $MARK
EOF

      # Policy routing по mark: именно эту схему использует Mihomo для multi-VETH.
      if [ "$RENDER_ONLY" = 0 ]; then
        if ! ip rule show | grep -q "fwmark $MARK_HEX lookup $TABLE"; then
          ip rule add fwmark "$MARK" table "$TABLE" pref "$RULE_PREF"
        fi
        ip route replace "$SRC_CIDR" dev "$IFACE" src "$SRC_IP" table "$TABLE"
      fi

      # задать шлюзом интерфейса VETH соседний контейнер в той же подсети, если задана переменная
      # нормализуем имя интерфейса и IP для поиска переменной
      SAFE_IFACE=$(echo "$IFACE" | tr '-' '_')
      SAFE_IP=$(echo "$SRC_IP" | tr '.' '_')
      VAR_GATEWAY_IP="GATEWAY_${SAFE_IP}"
      VAR_GATEWAY_IFACE="GATEWAY_${SAFE_IFACE}"
      # сначала проверяем gateway по IP
      if printenv "$VAR_GATEWAY_IP" >/dev/null; then GATEWAY_VETH=$(printenv "$VAR_GATEWAY_IP"); \
        # потом по интерфейсу
        elif printenv "$VAR_GATEWAY_IFACE" >/dev/null; then GATEWAY_VETH=$(printenv "$VAR_GATEWAY_IFACE"); \
        # fallback
        else GATEWAY_VETH="$GATEWAY"; \
      fi
      if [ "$RENDER_ONLY" = 0 ]; then
        ip route replace default via "$GATEWAY_VETH" dev "$IFACE" table "$TABLE"
      fi

      i=$((i+1))
    done
    if [ "$i" -gt 0 ]; then
      add_provider "VETH" "file" "$veth_file"
    fi
  fi
fi

# Empty groups remain valid even with no subscriptions or Ethernet interfaces.
if [ -z "$PROVIDERS_LIST" ]; then
  PROVIDERS_LIST="      []
    proxies:
      - DIRECT"
fi

# правила nft для настройки tproxy
nft_rules() {
  command -v nft >/dev/null || fail "tproxy mode requires nftables"
  nft delete table inet prizrak_tproxy 2>/dev/null || true

 # --- nftables table ---
  nft add table inet prizrak_tproxy

  # --- divert chain для ускорения TCP ---
  nft "add chain inet prizrak_tproxy divert {
    type filter hook prerouting priority mangle - 5;
    policy accept;
  }"

  # --- socket transparent (ускоряет established TCP) ---
  nft add rule inet prizrak_tproxy divert \
    meta l4proto tcp socket transparent 1 \
    meta mark set $TPROXY_MARK \
    accept

  # --- prerouting (mangle, но не слишком рано) ---
  nft "add chain inet prizrak_tproxy prerouting {
    type filter hook prerouting priority mangle;
    policy accept;
  }"

  # --- исключаем все локальные сервисы и служебные адреса ---
  if ! nft add rule inet prizrak_tproxy prerouting fib daddr type { local, broadcast, multicast } return 2>/dev/null; then
    # for ros < 7.22
    nft add rule inet prizrak_tproxy prerouting ip daddr { 0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255, $LOCAL_IPS } return
  fi

  # --- защита от MPTCP ---
  nft add rule inet prizrak_tproxy prerouting tcp option mptcp exists drop

  # --- TPROXY ---
  nft add rule inet prizrak_tproxy prerouting \
    iifname \""$FIRST_IFACE"\" \
    meta l4proto { tcp, udp } \
    meta mark set $TPROXY_MARK \
    tproxy ip to 127.0.0.1:$TPROXY_PORT \
    accept

  # --- policy routing ---
  if ! ip rule show | grep -q "fwmark $TPROXY_MARK lookup $TPROXY_TABLE"; then
    ip rule add fwmark $TPROXY_MARK lookup $TPROXY_TABLE pref 100
  fi
  ip route replace local 0.0.0.0/0 dev lo table $TPROXY_TABLE proto static scope host

  # если ядро без IPv6 — просто пропускаем
  [ -f /proc/net/if_inet6 ] && [ "${IPV6:-true}" = true ] || return 0

  # --- TPROXY IPv6 ---
  nft add rule inet prizrak_tproxy prerouting \
      iifname \""$FIRST_IFACE"\" \
      meta l4proto { tcp, udp } \
      meta mark set $TPROXY_MARK \
      tproxy ip6 to [::1]:$TPROXY_PORT \
      accept

  # --- policy routing IPv6 ---
  if ! ip -6 rule show | grep -q "fwmark $TPROXY_MARK lookup $TPROXY_TABLE"; then
    ip -6 rule add fwmark $TPROXY_MARK lookup $TPROXY_TABLE pref 100
  fi
  ip -6 route replace local ::/0 dev lo table $TPROXY_TABLE
}

# Generate the listener independently of privileges; --render-config never
# installs firewall rules, routes, or invokes user scripts.
TUN_IN_AUTOCONFIG=""
LISTENER_MODE="$NETWORK_MODE"
if [ "$NETWORK_MODE" = "mikrotik" ]; then
  if [ "${TUN:-0}" = 1 ] || [ "$NFT_CORE" -eq 0 ]; then
    LISTENER_MODE=tun
  else
    LISTENER_MODE=tproxy
  fi
fi

if [ "${ENVSUBST:-1}" = 1 ] && grep -Eq '^[[:space:]]*\$TUN_IN_AUTOCONFIG' "$CONFIG_FILE"; then
  case "$LISTENER_MODE" in
    tun)
      if [ "$RENDER_ONLY" = 0 ] && [ ! -c /dev/net/tun ] && [ ! -c /dev/tun ]; then
        fail "TUN requires /dev/net/tun or /dev/tun; mount the device and add NET_ADMIN, or choose NETWORK_MODE=proxy"
      fi
      TUN_IN_AUTOCONFIG=$(cat <<EOF
  - name: tun-in
    type: tun
    stack: $TUN_STACK
    auto-detect-interface: $TUN_AUTO_DETECT_INTERFACE
    auto-route: $TUN_AUTO_ROUTE
    auto-redirect: $TUN_AUTO_REDIRECT
    inet4-address:
    - $TUN_INET4_ADDRESS
    inet6-address:
    - $TUN_INET6_ADDRESS
    dns-hijack:
    - any:53
    - tcp://any:53
    udp-timeout: 300
    disable-icmp-forwarding: $TUN_DISABLE_ICMP_FORWARDING
EOF
)
      ;;
    tproxy)
      # An IPv4 bind cannot receive the IPv6 packets redirected to ::1.
      # The core enables IPv6 transparent socket options for an IPv6 bind.
      TPROXY_BIND_ADDRESS=0.0.0.0
      if [ "${IPV6:-true}" = true ] && [ -f /proc/net/if_inet6 ]; then
        TPROXY_BIND_ADDRESS=::
      fi
      if [ "$RENDER_ONLY" = 0 ]; then
        nft_rules
      fi
      TUN_IN_AUTOCONFIG=$(cat <<EOF
  - name: tun-in
    type: tproxy
    listen: "$TPROXY_BIND_ADDRESS"
    port: $TPROXY_PORT
    udp: true
EOF
)
      ;;
  esac
fi
export TUN_IN_AUTOCONFIG

# User hooks retain the original shared-shell environment during real startup.
if [ "$RENDER_ONLY" = 0 ]; then
  for script in "$USER_SH_DIR"/*.sh; do
    [ -f "$script" ] || continue
    log "Running user scripts: $script"
    . "$script"
  done
fi

export PROVIDERS_BLOCK PROVIDERS_LIST HWID

if [ "${ENVSUBST:-1}" = 1 ]; then
  envsubst < "$CONFIG_FILE" > "$WORKDIR/$CONFIG"
fi

if [ "$RENDER_ONLY" = 1 ]; then
  printf '%s\n' "$WORKDIR/$CONFIG"
  exit 0
fi

log "Network mode: $NETWORK_MODE"
log "$(prizrak-core -v)"
exec prizrak-core -d "$WORKDIR" -f "$WORKDIR/$CONFIG"
