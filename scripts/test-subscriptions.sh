#!/bin/bash
set -euo pipefail

IMAGE="${1:-mihomo-prizrak-docker:local}"

# Every service and HTTP fixture runs inside one unprivileged network namespace.
docker run --rm -i --network none --cap-drop ALL --entrypoint bash "$IMAGE" -euo pipefail -s <<'SCRIPT'
test_root=$(mktemp -d /tmp/prizrak-subscriptions.XXXXXX)
server_pid=""
core_pid=""
phase=setup

cleanup() {
  result=$?
  trap - EXIT
  set +e
  if [ "$result" != 0 ]; then
    printf 'Subscription test failed during: %s\n' "$phase" >&2
    for file in "$test_root"/*.log; do
      [ -f "$file" ] || continue
      printf '\nLog: %s\n' "${file##*/}" >&2
      cat "$file" >&2
    done
  fi
  [ -z "$core_pid" ] || kill "$core_pid" 2>/dev/null
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null
  [ -z "$core_pid" ] || wait "$core_pid" 2>/dev/null
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null
  rm -rf -- "$test_root"
  exit "$result"
}
trap cleanup EXIT

fail() { printf '%s\n' "$*" >&2; exit 1; }
has() { grep -Fq -- "$2" "$1" || fail "Expected '$2' in ${1##*/}"; }
lacks() {
  if grep -Fq -- "$2" "$1"; then fail "Unexpected '$2' in ${1##*/}"; fi
}
render() { /entrypoint.sh --render-config >"$test_root/$phase.log" 2>&1; }
validate() {
  prizrak-core -t -d "$WORKDIR" -f "$WORKDIR/$CONFIG" >>"$test_root/$phase.log" 2>&1
}

export FIXTURE_ROOT="$test_root/fixtures"
mkdir -p "$FIXTURE_ROOT"
: > "$FIXTURE_ROOT/headers"

write_full() {
  local destination="$1" marker="$2"
  cat > "$destination.new" <<EOF
mixed-port: 7890
mode: rule
port: 7891
socks-port: 7892
redir-port: 7893
tproxy-port: 7894
external-controller: 127.0.0.1:9091
external-controller-tls: 127.0.0.1:9092
external-ui: foreign-ui
external-ui-url: https://foreign.invalid/panel.zip
secret: foreign-secret
find-process-mode: always
log-level: debug
ipv6: false
tun:
  enable: true
  stack: gvisor
  exclude-package: [example.phone.app]
listeners:
  - name: foreign-listener
    type: mixed
    port: 7899
dns:
  enable: true
  listen: 127.0.0.1:9053
  enhanced-mode: redir-host
  ipv6: false
  nameserver: [system]
  nameserver-policy:
    '+.fixture.invalid': [system]
proxies:
  - name: source-direct
    type: direct
proxy-groups:
  - name: source-select
    type: select
    proxies: [source-direct]
rule-providers:
  inline-source:
    type: inline
    behavior: classical
    payload:
      - DOMAIN-SUFFIX,inline.invalid
rules:
  - DOMAIN,$marker,source-select
  - RULE-SET,inline-source,source-select
  - MATCH,source-select
EOF
  mv -- "$destination.new" "$destination"
}

write_full "$FIXTURE_ROOT/full.yaml" marker-v1.invalid
write_full "$FIXTURE_ROOT/full2.yaml" marker-v10.invalid
cat > "$FIXTURE_ROOT/nodes.yaml" <<'EOF'
proxies:
  - name: subscription-node
    type: direct
EOF
printf 'rules: [broken\n' > "$FIXTURE_ROOT/broken.yaml"
printf 'rules:\n  - MATCH,missing-group\n' > "$FIXTURE_ROOT/invalid.yaml"

cat > "$test_root/http-fixture" <<'EOF'
#!/bin/bash
set -eu
IFS= read -r request || exit 0
path="${request#* }"
path="${path%% *}"
path="${path%%\?*}"
while IFS= read -r header; do
  header="${header%$'\r'}"
  [ -n "$header" ] || break
  printf '%s\n' "$header" >> "$FIXTURE_ROOT/headers"
done
case "$path" in
  /full) file="$FIXTURE_ROOT/full.yaml" ;;
  /full2) file="$FIXTURE_ROOT/full2.yaml" ;;
  /nodes) file="$FIXTURE_ROOT/nodes.yaml" ;;
  /broken) file="$FIXTURE_ROOT/broken.yaml" ;;
  /invalid) file="$FIXTURE_ROOT/invalid.yaml" ;;
  *) printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'; exit 0 ;;
esac
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/yaml\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$(wc -c < "$file")"
cat "$file"
EOF
chmod +x "$test_root/http-fixture"
start_server() {
  busybox nc -lk -p 18080 -e "$test_root/http-fixture" >"$test_root/http.log" 2>&1 &
  server_pid=$!
  for attempt in {1..30}; do
    if curl -fsS --max-time 1 http://127.0.0.1:18080/nodes >/dev/null 2>&1; then return; fi
    kill -0 "$server_pid" 2>/dev/null || fail 'HTTP fixture exited'
    sleep 0.1
  done
  fail 'HTTP fixture did not become ready'
}
stop_server() {
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
}
start_server
base_url=http://127.0.0.1:18080
export CONFIG=default_config.yaml NETWORK_MODE=proxy UI_SECRET=subscription-test-secret
export PROXY_MODE=global
export HWID=fixture-hwid SUBSCRIPTION_TIMEOUT=1 SUBSCRIPTION_INTERVAL=0
export PROVIDER_HEADER_SUB1='X-Subscription-Test=fixture-header'
export SUB1="$base_url/full"
export SRV1='vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?security=tls&sni=example.com#standalone-node'

phase=full-config
export WORKDIR="$test_root/full"
render
validate
config="$WORKDIR/$CONFIG"
for expected in source-direct source-select inline-source marker-v1.invalid redir-host fixture.invalid ':9090' ':1053' 'port: 20170' 'Zephyruso/zashboard'; do
  has "$config" "$expected"
done
for unwanted in foreign-secret foreign-ui foreign-listener ':9091' ':9053' 'port: 789' gvisor exclude-package SELECTOR standalone-node; do
  lacks "$config" "$unwanted"
done
has "$config" "secret: $UI_SECRET"
has "$config" 'mode: global'
grep -qi '^x-hwid: fixture-hwid$' "$FIXTURE_ROOT/headers"
grep -qi '^User-Agent: clash.meta$' "$FIXTURE_ROOT/headers"
grep -qi '^X-Subscription-Test: fixture-header$' "$FIXTURE_ROOT/headers"

phase=offline-cache
cp -- "$config" "$test_root/last-good.yaml"
stop_server
render
cmp -- "$config" "$test_root/last-good.yaml"

phase=cache-url-binding
export SUB1="$base_url/new-url"
if render; then fail 'An unavailable new URL used another URL cache'; fi
cmp -- "$config" "$test_root/last-good.yaml"
start_server

for invalid_source in broken invalid; do
  phase="invalid-$invalid_source"
  export SUB1="$base_url/$invalid_source"
  if render; then fail 'An invalid initial configuration was accepted'; fi
  cmp -- "$config" "$test_root/last-good.yaml"
done

phase=full-after-node-source
export WORKDIR="$test_root/priority" SUB1="$base_url/nodes" SUB2="$base_url/full" SUB10="$base_url/full2"
render
validate
has "$WORKDIR/$CONFIG" marker-v1.invalid
lacks "$WORKDIR/$CONFIG" marker-v10.invalid
lacks "$WORKDIR/$CONFIG" SELECTOR
unset SUB2 SUB10

phase=node-template
export WORKDIR="$test_root/nodes" SUB1="$base_url/nodes"
render
validate
has "$WORKDIR/$CONFIG" SELECTOR
has "$WORKDIR/$CONFIG" 'DOMAIN-SUFFIX,lan,DIRECT'
has "$WORKDIR/$CONFIG" 'store-fake-ip: true'
has "$WORKDIR/srv.yaml" standalone-node
lacks "$WORKDIR/$CONFIG" source-select
mkdir -p "$WORKDIR/ui"
printf '%s\n' "$EXTERNAL_UI_URL" > "$WORKDIR/.ui_url"
printf '<html>test UI</html>\n' > "$WORKDIR/ui/index.html"
/entrypoint.sh >"$test_root/node-runtime.log" 2>&1 &
core_pid=$!
providers_ready=0
for attempt in {1..60}; do
  if curl -fsS --max-time 1 -H "Authorization: Bearer $UI_SECRET" \
    http://127.0.0.1:9090/providers/proxies/SUB1 >"$test_root/sub-provider.json" 2>/dev/null \
    && curl -fsS --max-time 1 -H "Authorization: Bearer $UI_SECRET" \
    http://127.0.0.1:9090/providers/proxies/SRV >"$test_root/srv-provider.json" 2>/dev/null \
    && grep -Fq subscription-node "$test_root/sub-provider.json" \
    && grep -Fq standalone-node "$test_root/srv-provider.json"; then
    providers_ready=1
    break
  fi
  kill -0 "$core_pid" 2>/dev/null || fail 'The core exited while loading node providers'
  sleep 0.2
done
[ "$providers_ready" = 1 ] || fail 'Native HTTP and URI providers did not load their nodes'
kill "$core_pid"
wait "$core_pid"
core_pid=""

phase=explicit-config
export WORKDIR="$test_root/custom" CONFIG=custom.yaml SUB1="$base_url/invalid"
mkdir -p "$WORKDIR"
printf 'mixed-port: 20172\nrules:\n  - MATCH,DIRECT\n' > "$test_root/custom-original.yaml"
cp -- "$test_root/custom-original.yaml" "$WORKDIR/$CONFIG"
render
cmp -- "$test_root/custom-original.yaml" "$WORKDIR/$CONFIG"
validate

phase=live-refresh
export WORKDIR="$test_root/refresh" CONFIG=default_config.yaml SUB1="$base_url/full" SUBSCRIPTION_INTERVAL=1
mkdir -p "$WORKDIR/ui"
# Keep this test offline: source loading is local and a UI already exists.
printf '%s\n' "$EXTERNAL_UI_URL" > "$WORKDIR/.ui_url"
printf '<html>test UI</html>\n' > "$WORKDIR/ui/index.html"
cat > "$test_root/config-tool" <<'EOF'
#!/bin/bash
set -eu
if [ "$1" = reload ] && [ -f "$FIXTURE_ROOT/fail-reload" ]; then
  # Reject the proposed config, then allow the updater to apply its rollback.
  if [ -f "$FIXTURE_ROOT/reload-rejected" ]; then
    rm -- "$FIXTURE_ROOT/reload-rejected"
  else
    : > "$FIXTURE_ROOT/reload-rejected"
    export UI_SECRET=not-the-api-secret
  fi
fi
exec /usr/bin/prizrak-config "$@"
EOF
chmod +x "$test_root/config-tool"
export SUBSCRIPTION_TOOL="$test_root/config-tool"
/entrypoint.sh >"$test_root/live-refresh.log" 2>&1 &
core_pid=$!
api_rules() {
  curl -fsS --max-time 1 -H "Authorization: Bearer $UI_SECRET" http://127.0.0.1:9090/rules
}
wait_rule() {
  local marker="$1"
  for attempt in {1..60}; do
    if api_rules >"$test_root/rules.json" 2>/dev/null && grep -Fq "$marker" "$test_root/rules.json"; then return; fi
    kill -0 "$core_pid" 2>/dev/null || fail 'The core exited during refresh'
    sleep 0.2
  done
  fail "The live API did not expose $marker"
}
wait_log() {
  local marker="$1"
  for attempt in {1..60}; do
    if grep -Fq "$marker" "$test_root/live-refresh.log"; then return; fi
    kill -0 "$core_pid" 2>/dev/null || fail 'The core exited during refresh'
    sleep 0.2
  done
  fail "The updater did not report $marker"
}
wait_rule marker-v1.invalid
curl -fsS --max-time 2 -H "Authorization: Bearer $UI_SECRET" http://127.0.0.1:9090/configs > "$test_root/mode.json"
has "$test_root/mode.json" '"mode":"global"'
write_full "$FIXTURE_ROOT/full.yaml" marker-v2.invalid
wait_rule marker-v2.invalid
curl -fsS --max-time 2 -H "Authorization: Bearer $UI_SECRET" http://127.0.0.1:9090/configs > "$test_root/mode.json"
has "$test_root/mode.json" '"mode":"global"'
kill -0 "$core_pid"
cp -- "$WORKDIR/$CONFIG" "$test_root/refreshed-good.yaml"

phase=invalid-refresh
printf 'rules: [broken\n' > "$FIXTURE_ROOT/full.yaml.new"
mv -- "$FIXTURE_ROOT/full.yaml.new" "$FIXTURE_ROOT/full.yaml"
wait_log 'response is invalid'
wait_rule marker-v2.invalid
cmp -- "$WORKDIR/$CONFIG" "$test_root/refreshed-good.yaml"

phase=reload-rollback
: > "$FIXTURE_ROOT/fail-reload"
write_full "$FIXTURE_ROOT/full.yaml" marker-v3.invalid
wait_log 'reload failed'
wait_rule marker-v2.invalid
cmp -- "$WORKDIR/$CONFIG" "$test_root/refreshed-good.yaml"

phase=outage-after-failed-reload
stop_server
rm -- "$FIXTURE_ROOT/fail-reload"
wait_log 'download failed'
# Give cached data an update cycle: a wrongly committed v3 cache would apply it.
sleep 2
api_rules > "$test_root/rules.json"
has "$test_root/rules.json" marker-v2.invalid
lacks "$test_root/rules.json" marker-v3.invalid
cmp -- "$WORKDIR/$CONFIG" "$test_root/refreshed-good.yaml"
kill -0 "$core_pid"

printf 'Subscription integration tests passed\n'
SCRIPT
