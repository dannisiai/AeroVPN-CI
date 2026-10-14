package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// benignConfigJSON mirrors the exact document SingboxConfigBuilder.buildConfig
// emits for a vless node (the control plane's default protocol).
const benignConfigJSON = `{
  "log": {"level": "warn", "timestamp": true},
  "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090", "secret": "0123456789abcdef0123456789abcdef"}},
  "dns": {
    "servers": [
      {"type": "udp", "tag": "dns-remote", "server": "1.1.1.1", "detour": "proxy"},
      {"type": "local", "tag": "dns-direct", "detour": "direct"}
    ],
    "rules": [{"domain_suffix": ["ethworldcupcoin.xyz", ".cn"], "server": "dns-direct"}],
    "final": "dns-remote",
    "strategy": "ipv4_only"
  },
  "inbounds": [{
    "type": "tun", "tag": "tun-in", "interface_name": "tun0",
    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
    "auto_route": true, "strict_route": true, "stack": "mixed",
    "exclude_interface": ["tun0", "wintun"]
  }],
  "outbounds": [
    {"type": "vless", "tag": "proxy", "server": "192.0.2.10", "server_port": 443,
     "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811", "flow": "xtls-rprx-vision",
     "tls": {"enabled": true, "server_name": "gateway.example.com",
             "utls": {"enabled": true, "fingerprint": "chrome"},
             "reality": {"enabled": true, "public_key": "pbk", "short_id": "ab12"}},
     "packet_encoding": "xudp"},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "default_domain_resolver": "dns-direct",
    "rules": [
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"inbound": ["tun-in"], "ip_cidr": ["172.19.0.0/30"], "action": "reject", "method": "drop"},
      {"ip_is_private": true, "outbound": "direct"},
      {"domain_suffix": ["ethworldcupcoin.xyz"], "outbound": "direct"}
    ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}`

const benignWireguardJSON = `{
  "log": {"level": "warn", "timestamp": true},
  "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090", "secret": "0123456789abcdef0123456789abcdef"}},
  "dns": {
    "servers": [{"type": "local", "tag": "dns-direct", "detour": "direct"}],
    "final": "dns-direct", "strategy": "ipv4_only"
  },
  "inbounds": [{"type": "tun", "tag": "tun-in", "interface_name": "tun0",
    "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true, "stack": "mixed"}],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "endpoints": [{
    "type": "wireguard", "tag": "proxy", "system": false, "mtu": 1420,
    "address": ["10.66.66.2/32"], "private_key": "cHJpdmF0ZWtleQ==",
    "peers": [{"address": "192.0.2.10", "port": 51820, "public_key": "cHVi",
      "reserved": [0, 0, 0], "allowed_ips": ["0.0.0.0/0", "::/0"],
      "persistent_keepalive_interval": 25}]
  }],
  "route": {"rules": [{"action": "sniff"}], "final": "proxy", "auto_detect_interface": true}
}`

func mustParse(t *testing.T, doc string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(doc), &m); err != nil {
		t.Fatalf("test fixture is not valid JSON: %v", err)
	}
	return m
}

func TestValidateConfigJSONAcceptsBuilderOutput(t *testing.T) {
	if err := ValidateConfigJSON([]byte(benignConfigJSON)); err != nil {
		t.Fatalf("benign vless config rejected: %v", err)
	}
	if err := ValidateConfigJSON([]byte(benignWireguardJSON)); err != nil {
		t.Fatalf("benign wireguard config rejected: %v", err)
	}
	customPortDoc := mutated(t, "custom_port", func(d map[string]any) {
		d["experimental"].(map[string]any)["clash_api"].(map[string]any)["external_controller"] = "127.0.0.1:9095"
	})
	if err := ValidateConfigJSON([]byte(customPortDoc)); err != nil {
		t.Fatalf("custom clash api port rejected: %v", err)
	}
}

// mutated runs a mutation against a copy of the benign document and re-marshals
// it, so injection does not depend on fragile string splicing.
func mutated(t *testing.T, name string, fn func(doc map[string]any)) string {
	t.Helper()
	doc := mustParse(t, benignConfigJSON)
	fn(doc)
	out, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal %s: %v", name, err)
	}
	return string(out)
}

// TestValidateConfigJSONRejectsPrivilegeEscalationOptions asserts the guard
// refuses every option that would give the SYSTEM-privileged core a
// filesystem, download or unrestricted-network side effect. Rejection is by
// whitelist absence: none of these keys exist in the schema at all.
func TestValidateConfigJSONRejectsPrivilegeEscalationOptions(t *testing.T) {
	cases := []struct {
		name string
		doc  string
	}{
		{"external_ui download+unzip", mutated(t, "external_ui", func(d map[string]any) {
			exp := d["experimental"].(map[string]any)
			exp["clash_api"].(map[string]any)["external_ui"] = `C:\Windows\Temp\ui`
			exp["clash_api"].(map[string]any)["external_ui_download_url"] = "http://attacker.invalid/ui.zip"
		})},
		{"external_ui_download_url only", mutated(t, "euidu", func(d map[string]any) {
			d["experimental"].(map[string]any)["clash_api"].(map[string]any)["external_ui_download_url"] = "http://attacker.invalid/ui.zip"
		})},
		{"log.output file write", mutated(t, "log_output", func(d map[string]any) {
			d["log"].(map[string]any)["output"] = `C:\Windows\Temp\x.log`
		})},
		{"cache_file", mutated(t, "cache_file", func(d map[string]any) {
			d["experimental"].(map[string]any)["cache_file"] = map[string]any{"enabled": true, "path": `C:\Windows\Temp\cache.db`}
		})},
		{"remote rule_set download", mutated(t, "rule_set", func(d map[string]any) {
			rules := d["route"].(map[string]any)["rules"].([]any)
			d["route"].(map[string]any)["rules"] = append(rules,
				map[string]any{"rule_set": []any{"http://attacker.invalid/x.srs"}, "outbound": "direct"})
		})},
		{"tls certificate_path read", mutated(t, "cert_path", func(d map[string]any) {
			ob := d["outbounds"].([]any)[0].(map[string]any)
			ob["tls"].(map[string]any)["certificate_path"] = `C:\ProgramData\secret.pem`
		})},
		{"unknown top-level key", mutated(t, "topkey", func(d map[string]any) {
			d["ssh"] = map[string]any{}
		})},
		{"unknown option inside tun inbound", mutated(t, "tunopt", func(d map[string]any) {
			d["inbounds"].([]any)[0].(map[string]any)["gso"] = true
		})},
		{"non-tun inbound", mutated(t, "mixed_in", func(d map[string]any) {
			d["inbounds"] = []any{
				map[string]any{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1:2080"},
			}
		})},
		{"second tun inbound", mutated(t, "two_tun", func(d map[string]any) {
			extra := mustParse(t, benignConfigJSON)["inbounds"].([]any)[0]
			d["inbounds"] = append(d["inbounds"].([]any), extra)
		})},
		{"extra proxy outbound", mutated(t, "extra_ob", func(d map[string]any) {
			d["outbounds"] = append(
				d["outbounds"].([]any)[:1],
				map[string]any{"type": "vless", "tag": "evil", "server": "192.0.2.9", "server_port": 1,
					"uuid": "b831381d-6324-4d53-ad4f-8cda48b30811", "tls": map[string]any{"enabled": true}},
				map[string]any{"type": "direct", "tag": "direct"},
			)
		})},
		{"outbound tag not proxy", mutated(t, "ob_tag", func(d map[string]any) {
			d["outbounds"].([]any)[0].(map[string]any)["tag"] = "evil"
		})},
		{"route.final override", mutated(t, "final", func(d map[string]any) {
			d["route"].(map[string]any)["final"] = "direct"
		})},
		{"route rule to unknown tag", mutated(t, "rule_ref", func(d map[string]any) {
			rules := d["route"].(map[string]any)["rules"].([]any)
			rules[4].(map[string]any)["outbound"] = "evil"
		})},
		{"dns detour to unknown tag", mutated(t, "detour_ref", func(d map[string]any) {
			d["dns"].(map[string]any)["servers"].([]any)[0].(map[string]any)["detour"] = "evil"
		})},
		{"clash secret weak", mutated(t, "secret", func(d map[string]any) {
			d["experimental"].(map[string]any)["clash_api"].(map[string]any)["secret"] = ""
		})},
		{"clash controller moved", mutated(t, "controller", func(d map[string]any) {
			d["experimental"].(map[string]any)["clash_api"].(map[string]any)["external_controller"] = "0.0.0.0:9090"
		})},
		{"clash controller privileged port", mutated(t, "port_low", func(d map[string]any) {
			d["experimental"].(map[string]any)["clash_api"].(map[string]any)["external_controller"] = "127.0.0.1:80"
		})},
		{"clash controller non loopback", mutated(t, "port_remote", func(d map[string]any) {
			d["experimental"].(map[string]any)["clash_api"].(map[string]any)["external_controller"] = "192.168.1.1:9090"
		})},
		{"URL smuggled as server", mutated(t, "url_server", func(d map[string]any) {
			d["outbounds"].([]any)[0].(map[string]any)["server"] = "http://attacker.invalid/x"
		})},
		{"path smuggled as server", mutated(t, "path_server", func(d map[string]any) {
			d["outbounds"].([]any)[0].(map[string]any)["server"] = "../../etc/passwd"
		})},
		{"vless flow unknown", mutated(t, "flow", func(d map[string]any) {
			d["outbounds"].([]any)[0].(map[string]any)["flow"] = "xtls-rprx-dynamic"
		})},
		{"route rule to proxy bypass", mutated(t, "rule_proxy", func(d map[string]any) {
			rules := d["route"].(map[string]any)["rules"].([]any)
			rules[4].(map[string]any)["domain_suffix"] = []any{"*"}
		})},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := ValidateConfigJSON([]byte(tc.doc)); err == nil {
				t.Fatalf("%s was accepted; the whitelist must refuse it", tc.name)
			}
		})
	}
}

func TestValidateConfigJSONRejectsMalformedInput(t *testing.T) {
	bad := []string{
		``,
		`not json`,
		`[1,2,3]`,
		`{"log":{}} {"log":{}}`,
		`{"inbounds": []}`,
	}
	for _, doc := range bad {
		if err := ValidateConfigJSON([]byte(doc)); err == nil {
			t.Fatalf("malformed config %q was accepted", doc)
		}
	}
	huge := `{"pad":"` + strings.Repeat("a", maxConfigBytes) + `"}`
	if err := ValidateConfigJSON([]byte(huge)); err == nil {
		t.Fatal("oversized config was accepted")
	}
}
