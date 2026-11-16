package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestClassifySubscriptionFormats(t *testing.T) {
	uri := "vless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls#A"
	xray := `{"outbounds":[{"protocol":"vless","settings":{"vnext":[]}}],"dns":{"servers":["localhost"]}}`
	cases := []struct {
		name, data, kind string
	}{
		{"Mihomo rules", "proxies: []\nrules: [MATCH,DIRECT]\n", "full"},
		{"Mihomo JSON", `{"rules":["MATCH,DIRECT"],"proxies":[]}`, "full"},
		{"nested providers", "proxy-providers:\n  subscribed:\n    type: http\n    url: https://example.com/nodes\nproxy-groups: []\n", "full"},
		{"DNS-only config", "dns:\n  enable: false\n", "full"},
		{"proxies only", "proxies:\n  - name: direct\n    type: direct\n", "nodes"},
		{"empty proxies", "proxies: []\n", "nodes"},
		{"node URIs", "# comment\n" + uri + "\n\nhysteria2://password@example.com:443#B\n", "nodes"},
		{"Xray DNS does not make full", xray, "nodes"},
		{"Xray array", "[" + xray + "]", "nodes"},
		{"base64 URIs", base64.StdEncoding.EncodeToString([]byte(uri)), "nodes"},
		{"raw base64 URIs", base64.RawStdEncoding.EncodeToString([]byte(uri)), "nodes"},
		{"URL base64 Xray", base64.URLEncoding.EncodeToString([]byte(xray)), "nodes"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			kind, err := classify([]byte(tc.data))
			if err != nil || kind != tc.kind {
				t.Fatalf("classify() = %q, %v; want %q", kind, err, tc.kind)
			}
		})
	}
}

func TestClassifyRejectsMalformedOrUnknownSource(t *testing.T) {
	for _, data := range []string{
		"", " \n", "rules: [broken", "<html>Access denied</html>",
		"proxies: wrong", "unrelated: value", "---\nrules: []\n---\nproxies: []\n",
		"rules: []\nrules: [MATCH,DIRECT]\n",
	} {
		if kind, err := classify([]byte(data)); err == nil {
			t.Errorf("classify(%q) = %q; want an error", data, kind)
		}
	}
}

const baseConfiguration = `
external-controller: 0.0.0.0:9090
external-ui: ui
external-ui-url: https://example.com/zashboard.zip
secret: container-secret
find-process-mode: "off"
log-level: info
ipv6: true
listeners:
  - name: mixed-in
    type: mixed
    listen: 0.0.0.0
    port: 20170
  - name: tun-in
    type: tun
    stack: mips
    auto-route: true
dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  nameserver: [system]
proxy-providers:
  must-not-be-merged:
    type: file
    path: local.yaml
proxy-groups:
  - name: SELECTOR
    type: select
    proxies: [DIRECT]
rules:
  - MATCH,SELECTOR
`

func decodedMapping(t *testing.T, data []byte) map[string]any {
	t.Helper()
	document, err := decode(data)
	if err != nil {
		t.Fatal(err)
	}
	mapping, ok := document.(map[string]any)
	if !ok {
		t.Fatalf("expected mapping, got %T", document)
	}
	return mapping
}

func TestApplyPreservesSubscriptionPolicyAndReplacesInfrastructure(t *testing.T) {
	source := []byte(`
mode: rule
mixed-port: 7890
port: 7891
socks-port: 7892
redir-port: 7893
tproxy-port: 7894
bind-address: "*"
allow-lan: true
lan-allowed-ips: [0.0.0.0/0]
lan-disallowed-ips: [10.0.0.0/8]
authentication: [mobile:password]
skip-auth-prefixes: [127.0.0.1/32]
external-controller: :9999
external-controller-tls: :9998
external-controller-unix: /tmp/foreign.sock
external-controller-pipe: foreign-pipe
external-controller-cors: {allow-origins: ['*']}
external-ui: foreign-ui
external-ui-url: https://example.com/foreign.zip
external-ui-name: nested
secret: foreign-secret
interface-name: phone-vpn
routing-mark: 1234
find-process-mode: always
log-level: debug
ipv6: false
ss-config: :7788
vmess-config: :7789
tuic-server: {enable: true, listen: ":7790"}
tunnels: ["tcp/0.0.0.0:7791/example.com:80,DIRECT"]
iptables: {enable: true}
tun: {enable: true, stack: gvisor}
listeners: [{name: foreign-in, type: socks, port: 7888}]
dns:
  enable: false
  listen: 0.0.0.0:53
  enhanced-mode: redir-host
  nameserver: [https://example.com/dns-query]
  nameserver-policy:
    '+.home.arpa': 192.168.88.1
proxies:
  - name: Foreign Node
    type: direct
    interface-name: wg0
proxy-providers:
  foreign-provider:
    type: http
    url: https://example.com/nodes
proxy-groups:
  - name: Foreign Group
    type: select
    proxies: [Foreign Node]
rule-providers:
  custom:
    type: inline
    behavior: classical
    payload: ["DOMAIN,example.com"]
rules:
  - DOMAIN,example.com,Foreign Group
  - MATCH,DIRECT
profile: {store-selected: true, store-fake-ip: true}
x-custom-extension: {answer: 42}
`)
	adapted, err := apply(source, []byte(baseConfiguration))
	if err != nil {
		t.Fatal(err)
	}
	got := decodedMapping(t, adapted)
	original := decodedMapping(t, source)
	runtime := decodedMapping(t, []byte(baseConfiguration))

	for _, key := range []string{"mode", "proxies", "proxy-providers", "proxy-groups", "rule-providers", "rules", "profile", "x-custom-extension"} {
		if !reflect.DeepEqual(got[key], original[key]) {
			t.Errorf("source %s changed: got %#v; want %#v", key, got[key], original[key])
		}
	}
	for _, key := range []string{"listeners", "external-controller", "external-ui", "external-ui-url", "secret", "find-process-mode", "log-level", "ipv6"} {
		if !reflect.DeepEqual(got[key], runtime[key]) {
			t.Errorf("container %s not applied: got %#v; want %#v", key, got[key], runtime[key])
		}
	}
	for _, key := range []string{"port", "mixed-port", "socks-port", "redir-port", "tproxy-port", "tun", "ss-config", "vmess-config", "tuic-server", "tunnels", "iptables", "authentication", "skip-auth-prefixes", "allow-lan", "lan-allowed-ips", "lan-disallowed-ips", "bind-address", "interface-name", "routing-mark", "external-controller-tls", "external-controller-unix", "external-controller-pipe", "external-controller-cors", "external-ui-name"} {
		if _, exists := got[key]; exists {
			t.Errorf("foreign infrastructure key %q survived", key)
		}
	}
	dns := got["dns"].(map[string]any)
	originalDNS := original["dns"].(map[string]any)
	for _, key := range []string{"enable", "enhanced-mode", "nameserver", "nameserver-policy"} {
		if !reflect.DeepEqual(dns[key], originalDNS[key]) {
			t.Errorf("source DNS %s changed", key)
		}
	}
	if dns["listen"] != "0.0.0.0:1053" {
		t.Errorf("DNS listener not replaced: %#v", dns["listen"])
	}
}

func TestApplyExpandsAliasesWithoutDanglingDeletedAnchors(t *testing.T) {
	adapted, err := apply([]byte(`
mixed-port: &port 7890
x-dns: &dns
  enable: true
  nameserver: [https://example.com/dns-query]
  listen: 127.0.0.1:53
dns:
  <<: *dns
  enhanced-mode: redir-host
proxies:
  - name: alias-node
    type: http
    server: example.com
    port: *port
rules: [MATCH,DIRECT]
`), []byte(baseConfiguration))
	if err != nil {
		t.Fatal(err)
	}
	got := decodedMapping(t, adapted)
	proxy := got["proxies"].([]any)[0].(map[string]any)
	if proxy["port"] != 7890 {
		t.Errorf("alias value lost: %#v", proxy)
	}
	dns := got["dns"].(map[string]any)
	if dns["enhanced-mode"] != "redir-host" || dns["listen"] != "0.0.0.0:1053" || len(dns["nameserver"].([]any)) != 1 {
		t.Errorf("merged DNS changed: %#v", dns)
	}
}

func TestApplySuppliesDNSOnlyWhenAbsent(t *testing.T) {
	for _, source := range []string{"rules: [MATCH,DIRECT]\n", "rules: [MATCH,DIRECT]\ndns: null\n"} {
		adapted, err := apply([]byte(source), []byte(baseConfiguration))
		if err != nil {
			t.Fatal(err)
		}
		got := decodedMapping(t, adapted)
		runtime := decodedMapping(t, []byte(baseConfiguration))
		if !reflect.DeepEqual(got["dns"], runtime["dns"]) {
			t.Error("absent DNS did not receive runtime defaults")
		}
	}
	if _, err := apply([]byte("proxies: []\n"), []byte(baseConfiguration)); err == nil {
		t.Error("node-only provider should not become the main configuration")
	}
	if _, err := apply([]byte("rules: []\ndns: wrong\n"), []byte(baseConfiguration)); err == nil {
		t.Error("malformed source DNS should be rejected")
	}
}

func TestYAMLContentNeverExecutesShell(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "must-not-exist")
	data := fmt.Sprintf("rules: [MATCH,DIRECT]\nx-shell: $(touch %s)\nx-tag: !!python/object/apply:os.system [false]\n", marker)
	adapted, err := apply([]byte(data), []byte(baseConfiguration))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(adapted, []byte("$(touch "+marker+")")) {
		t.Error("literal shell-looking content was not preserved")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("YAML content executed: %v", err)
	}
}

func TestReloadUsesExactPathAndSecret(t *testing.T) {
	path := "/etc/mihomo/config with \"quotes\".yaml"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut || r.URL.Path != "/configs" || r.URL.Query().Get("force") != "true" {
			t.Errorf("unexpected reload request: %s %s", r.Method, r.URL)
		}
		if r.Header.Get("Authorization") != "Bearer exact-secret" {
			t.Error("controller secret missing")
		}
		var body struct{ Path string }
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Path != path {
			t.Errorf("reload path not preserved: %#v, %v", body, err)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	if err := reload(strings.TrimPrefix(server.URL, "http://"), path, "exact-secret", server.Client()); err != nil {
		t.Fatal(err)
	}
}

func TestReloadStatusDoesNotDiscloseResponseOrCredentials(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		fmt.Fprintln(w, "sensitive subscription body and exact-secret")
	}))
	defer server.Close()
	err := reload(strings.TrimPrefix(server.URL, "http://"), "/etc/mihomo/config.yaml", "exact-secret", server.Client())
	if err == nil || err.Error() != "configuration API returned HTTP 401" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestReloadCLIRejectsRedirectWithoutSendingSecret(t *testing.T) {
	redirected := false
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirected = true
		t.Error("reload followed a redirect")
		w.WriteHeader(http.StatusNoContent)
	}))
	defer destination.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL, http.StatusFound)
	}))
	defer server.Close()
	t.Setenv("UI_SECRET", "must-stay-local")
	err := run([]string{"reload", "--controller", strings.TrimPrefix(server.URL, "http://"), "--path", "/tmp/config.yaml"}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "HTTP 302") || redirected {
		t.Fatalf("unexpected redirect result: %v, followed=%v", err, redirected)
	}
}

func TestControllerWildcardNormalization(t *testing.T) {
	for controller, want := range map[string]string{
		"0.0.0.0:9090":   "http://127.0.0.1:9090/configs?force=true",
		":9090":          "http://127.0.0.1:9090/configs?force=true",
		"[::]:9090":      "http://[::1]:9090/configs?force=true",
		"[::1]:9090":     "http://[::1]:9090/configs?force=true",
		"localhost:9090": "http://localhost:9090/configs?force=true",
	} {
		got, err := controllerURL(controller)
		if err != nil || got != want {
			t.Errorf("controllerURL(%q) = %q, %v; want %q", controller, got, err, want)
		}
	}
	for _, controller := range []string{"", "http://example.com:9090", "example.com", "[::]:"} {
		if _, err := controllerURL(controller); err == nil {
			t.Errorf("invalid controller %q accepted", controller)
		}
	}
}
