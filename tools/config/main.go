// prizrak-config adapts subscription configuration to the container runtime.
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

const (
	maxConfigBytes = 32 << 20
	reloadTimeout  = 60 * time.Second
)

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "prizrak-config:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return errors.New("expected classify, apply, or reload command")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(stderr)
	switch args[0] {
	case "classify":
		input := flags.String("input", "", "subscription file")
		if err := parseFlags(flags, args[1:]); err != nil {
			return err
		}
		data, err := readConfig(*input)
		if err != nil {
			return err
		}
		kind, err := classify(data)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(stdout, kind)
		return err
	case "apply":
		source := flags.String("source", "", "full subscription configuration")
		base := flags.String("base", "", "generated container configuration")
		output := flags.String("output", "", "adapted configuration file")
		if err := parseFlags(flags, args[1:]); err != nil {
			return err
		}
		if *output == "" {
			return errors.New("--output is required")
		}
		sourceData, err := readConfig(*source)
		if err != nil {
			return err
		}
		baseData, err := readConfig(*base)
		if err != nil {
			return err
		}
		data, err := apply(sourceData, baseData)
		if err != nil {
			return err
		}
		if err := os.WriteFile(*output, data, 0o600); err != nil {
			return fmt.Errorf("cannot write adapted configuration: %w", err)
		}
		return nil
	case "reload":
		controller := flags.String("controller", "", "controller host:port")
		path := flags.String("path", "", "configuration file path")
		if err := parseFlags(flags, args[1:]); err != nil {
			return err
		}
		if *path == "" {
			return errors.New("--path is required")
		}
		return reload(*controller, *path, os.Getenv("UI_SECRET"), &http.Client{
			Timeout: reloadTimeout,
			// An API redirect must not send the controller secret elsewhere.
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
		})
	default:
		return errors.New("expected classify, apply, or reload command")
	}
}

func parseFlags(flags *flag.FlagSet, args []string) error {
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	return nil
}

func readConfig(path string) ([]byte, error) {
	if path == "" {
		return nil, errors.New("configuration file path is required")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read configuration: %w", err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxConfigBytes+1))
	if err != nil {
		return nil, fmt.Errorf("cannot read configuration: %w", err)
	}
	if len(data) > maxConfigBytes {
		return nil, errors.New("configuration exceeds 32 MiB")
	}
	return data, nil
}

// Decode through a generic value to expand aliases and merge keys. Keeping the
// aliases would leave dangling references when their infrastructure key is
// removed or replaced during adaptation.
func decode(data []byte) (any, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	var document any
	if err := decoder.Decode(&document); err != nil {
		return nil, errors.New("invalid YAML configuration")
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, errors.New("configuration must contain one YAML document")
	}
	return document, nil
}

func classify(data []byte) (string, error) {
	data = bytes.TrimSpace(bytes.TrimPrefix(data, []byte("\xef\xbb\xbf")))
	if len(data) == 0 {
		return "", errors.New("empty subscription")
	}
	if isURIList(string(data)) {
		return "nodes", nil
	}
	document, err := decode(data)
	if err != nil {
		return "", err
	}
	if isXrayJSON(document) {
		return "nodes", nil
	}
	if root, ok := document.(map[string]any); ok {
		for key := range root {
			if fullConfigKeys[key] {
				return "full", nil
			}
		}
		if proxies, exists := root["proxies"]; exists {
			if _, ok := proxies.([]any); ok {
				return "nodes", nil
			}
			return "", errors.New("subscription proxies must be a YAML list")
		}
	}
	if encoded, ok := document.(string); ok {
		// Encoded node subscriptions are handed to the native provider parser;
		// their routing policy still comes from the container template.
		compact := strings.Join(strings.Fields(encoded), "")
		for _, encoding := range []*base64.Encoding{
			base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding,
		} {
			decoded, err := encoding.DecodeString(compact)
			if err != nil || len(decoded) == 0 {
				continue
			}
			if isURIList(string(decoded)) {
				return "nodes", nil
			}
			if payload, err := decode(decoded); err == nil && isXrayJSON(payload) {
				return "nodes", nil
			}
		}
	}
	return "", errors.New("subscription is neither a Mihomo configuration nor a supported node list")
}

var fullConfigKeys = map[string]bool{
	"rules": true, "sub-rules": true, "rule-providers": true,
	"proxy-groups": true, "proxy-providers": true, "dns": true,
	"listeners": true, "tun": true, "mode": true, "profile": true,
	"hosts": true, "sniffer": true, "port": true, "socks-port": true,
	"mixed-port": true, "redir-port": true, "tproxy-port": true,
	"allow-lan": true, "bind-address": true, "external-controller": true,
	"external-ui": true, "external-ui-url": true,
}

func isURIList(text string) bool {
	found := false
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parsed, err := url.Parse(line)
		if err != nil || parsed.Scheme == "" || !strings.Contains(line, "://") || parsed.Host == "" {
			return false
		}
		found = true
	}
	return found
}

func isXrayJSON(document any) bool {
	switch value := document.(type) {
	case map[string]any:
		_, outbounds := value["outbounds"]
		_, inbounds := value["inbounds"]
		return outbounds || inbounds
	case []any:
		if len(value) == 0 {
			return false
		}
		for _, item := range value {
			if !isXrayJSON(item) {
				return false
			}
		}
		return true
	default:
		return false
	}
}

func apply(source, base []byte) ([]byte, error) {
	kind, err := classify(source)
	if err != nil {
		return nil, err
	}
	if kind != "full" {
		return nil, errors.New("a full Mihomo configuration is required")
	}
	sourceDocument, err := decode(source)
	if err != nil {
		return nil, err
	}
	root, ok := sourceDocument.(map[string]any)
	if !ok {
		return nil, errors.New("subscription configuration must be a YAML mapping")
	}
	baseDocument, err := decode(base)
	if err != nil {
		return nil, errors.New("invalid container base configuration")
	}
	runtime, ok := baseDocument.(map[string]any)
	if !ok {
		return nil, errors.New("container base configuration must be a YAML mapping")
	}
	listeners, ok := runtime["listeners"].([]any)
	if !ok || len(listeners) == 0 {
		return nil, errors.New("container base configuration must define listeners")
	}

	for _, key := range []string{
		"port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "tun",
		"ss-config", "vmess-config", "tuic-server", "tunnels", "iptables",
		"bind-address", "allow-lan", "lan-allowed-ips", "lan-disallowed-ips",
		"authentication", "skip-auth-prefixes", "interface-name", "routing-mark",
	} {
		delete(root, key)
	}
	for key := range root {
		if key == "external-controller" || strings.HasPrefix(key, "external-controller-") ||
			key == "external-ui" || strings.HasPrefix(key, "external-ui-") {
			delete(root, key)
		}
	}
	root["listeners"] = listeners
	for _, key := range []string{
		"external-controller", "external-ui", "external-ui-url", "secret",
		"find-process-mode", "log-level", "ipv6",
	} {
		if value, exists := runtime[key]; exists {
			root[key] = value
		} else {
			delete(root, key)
		}
	}

	runtimeDNS, ok := runtime["dns"].(map[string]any)
	if !ok {
		return nil, errors.New("container base configuration must define DNS settings")
	}
	if sourceDNS, exists := root["dns"]; exists && sourceDNS != nil {
		dns, ok := sourceDNS.(map[string]any)
		if !ok {
			return nil, errors.New("subscription DNS settings must be a YAML mapping")
		}
		if listen, exists := runtimeDNS["listen"]; exists {
			dns["listen"] = listen
		} else {
			delete(dns, "listen")
		}
	} else {
		root["dns"] = runtimeDNS
	}

	result, err := yaml.Marshal(root)
	if err != nil {
		return nil, errors.New("cannot encode adapted configuration")
	}
	return result, nil
}

func controllerURL(controller string) (string, error) {
	if strings.Contains(controller, "://") {
		return "", errors.New("controller must be a host:port address")
	}
	host, port, err := net.SplitHostPort(controller)
	if err != nil || port == "" {
		return "", errors.New("controller must be a host:port address")
	}
	switch host {
	case "", "0.0.0.0":
		host = "127.0.0.1"
	case "::":
		host = "::1"
	}
	return "http://" + net.JoinHostPort(host, port) + "/configs?force=true", nil
}

func reload(controller, path, secret string, client *http.Client) error {
	address, err := controllerURL(controller)
	if err != nil {
		return err
	}
	body, err := json.Marshal(struct {
		Path string `json:"path"`
	}{Path: path})
	if err != nil {
		return errors.New("cannot encode reload request")
	}
	ctx, cancel := context.WithTimeout(context.Background(), reloadTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPut, address, bytes.NewReader(body))
	if err != nil {
		return errors.New("cannot create reload request")
	}
	request.Header.Set("Content-Type", "application/json")
	if secret != "" {
		request.Header.Set("Authorization", "Bearer "+secret)
	}
	response, err := client.Do(request)
	if err != nil {
		return errors.New("cannot contact configuration API")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		// The response may echo configuration or credentials; only log status.
		return fmt.Errorf("configuration API returned HTTP %d", response.StatusCode)
	}
	return nil
}
