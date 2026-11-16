#!/bin/bash
set -euo pipefail

IMAGE="${1:-mihomo-prizrak-docker:local}"
docker run --rm --network none --cap-drop ALL "$IMAGE" -v

# Proxy startup must work with no network capabilities, including on a host
# with several interfaces. Fail if the entrypoint invokes any network tool.
docker run --rm --network none --cap-drop ALL \
  -e UI_SECRET=smoke-secret --entrypoint bash "$IMAGE" -euc '
    mkdir /tmp/network-tools
    for command in ip nft iptables ip6tables apk apt-get; do
      printf "#!/bin/sh\necho Unexpected network/package command >&2\nexit 99\n" > "/tmp/network-tools/$command"
      chmod +x "/tmp/network-tools/$command"
    done
    export PATH="/tmp/network-tools:$PATH"
    /entrypoint.sh --render-config
    prizrak-core -t -d "$WORKDIR" -f "$WORKDIR/$CONFIG"
    /entrypoint.sh >/tmp/prizrak.log 2>&1 &
    core_pid=$!
    trap '\''kill "$core_pid" 2>/dev/null || true'\'' EXIT
    ready=0
    for attempt in {1..50}; do
      if curl -fsS --connect-timeout 1 -H "Authorization: Bearer $UI_SECRET" http://127.0.0.1:9090/version >/tmp/version.json 2>/dev/null; then
        ready=1
        break
      fi
      kill -0 "$core_pid" 2>/dev/null || { cat /tmp/prizrak.log; exit 1; }
      sleep 0.2
    done
    [ "$ready" = 1 ] || { cat /tmp/prizrak.log; exit 1; }
    cat /tmp/version.json
    for proxy in http://127.0.0.1:1080 socks5h://127.0.0.1:1080; do
      curl -fsS --max-time 5 --noproxy "" --proxy "$proxy" \
        -H "Authorization: Bearer $UI_SECRET" http://127.0.0.1:9090/version
    done
  '

for mode in tun tproxy mikrotik; do
  docker run --rm --network none --cap-drop ALL \
    -e NETWORK_MODE="$mode" -e TPROXY_INTERFACE=eth0 \
    --entrypoint bash "$IMAGE" -euc '
      /entrypoint.sh --render-config
      prizrak-core -t -d "$WORKDIR" -f "$WORKDIR/$CONFIG"
    '
done

# File providers must preserve modern share links and skip unsupported nodes.
docker run --rm --network none --cap-drop ALL \
  -e 'SRV1=vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?type=xhttp&security=tls&sni=example.com&path=%2Ftest#xhttp' \
  -e 'SRV2=hysteria2://test-password@127.0.0.1:443?sni=example.com#hy2' \
  -e 'SRV3=unsupported://127.0.0.1:443#unsupported-node' \
  -e SUB1= -e UI_SECRET=smoke-secret --entrypoint bash "$IMAGE" -euc '
    /entrypoint.sh --render-config
    grep -q "type=xhttp" "$WORKDIR/srv.yaml"
    prizrak-core -t -d "$WORKDIR" -f "$WORKDIR/$CONFIG"
    /entrypoint.sh >/tmp/prizrak.log 2>&1 &
    core_pid=$!
    trap '\''kill "$core_pid" 2>/dev/null || true'\'' EXIT
    ready=0
    for attempt in {1..50}; do
      if curl -fsS --connect-timeout 1 -H "Authorization: Bearer $UI_SECRET" \
        http://127.0.0.1:9090/providers/proxies/SRV >/tmp/provider.json 2>/dev/null \
        && grep -q '\''"name":"xhttp"'\'' /tmp/provider.json \
        && grep -q '\''"name":"hy2"'\'' /tmp/provider.json; then
        ready=1
        break
      fi
      kill -0 "$core_pid" 2>/dev/null || { cat /tmp/prizrak.log; exit 1; }
      sleep 0.2
    done
    [ "$ready" = 1 ] || { cat /tmp/prizrak.log /tmp/provider.json; exit 1; }
    if grep -q '\''"name":"unsupported-node"'\'' /tmp/provider.json; then exit 1; fi
  '

# A user config and CLI arguments containing spaces must reach the core intact.
docker run --rm --network none --cap-drop ALL --entrypoint bash "$IMAGE" -euc '
  mkdir -p "/tmp/custom config"
  printf "mixed-port: 1080\nrules:\n  - MATCH,DIRECT\n" > "/tmp/custom config/config.yaml"
  /entrypoint.sh -t -d "/tmp/custom config" -f "/tmp/custom config/config.yaml"
  export CONFIG=custom.yaml
  cp "/tmp/custom config/config.yaml" "$WORKDIR/$CONFIG"
  /entrypoint.sh --render-config
  cmp "/tmp/custom config/config.yaml" "$WORKDIR/$CONFIG"
  prizrak-core -t -d "$WORKDIR" -f "$WORKDIR/$CONFIG"
  export DNS='\''$(touch /tmp/dns-command-executed)'\''
  export CONFIG=default_config.yaml
  /entrypoint.sh --render-config
  [ ! -e /tmp/dns-command-executed ]
  grep -Fq '\''$(touch /tmp/dns-command-executed)'\'' "$WORKDIR/$CONFIG"
  if NETWORK_MODE=invalid /entrypoint.sh --render-config; then exit 1; fi
'

printf '\nSmoke tests passed for %s\n' "$IMAGE"
