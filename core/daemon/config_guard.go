package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
)

// ValidateConfigJSON enforces a strict whitelist on the tunnel configuration
// before the SYSTEM-privileged daemon hands it to the official sing-box core.
//
// Threat model: /tunnel/start is reachable by any process running as the
// installing desktop user that knows the IPC token. The token protects the
// endpoint from *other* users; it cannot protect the SYSTEM core from the
// authorized user's own processes. A config string is therefore untrusted
// input: sing-box options such as experimental.clash_api.external_ui make the
// core download a ZIP from a config-controlled URL and extract it
// (upstream v1.14.3 experimental/clashapi/server_resources.go:22-97,
// downloadExternalUI + zip.OpenReader), and *_path options read or write
// files with SYSTEM rights.
//
// Defense: the daemon only ever needs the exact document shape produced by
// the client's SingboxConfigBuilder, so everything not in the whitelist below
// is rejected with a hard error before the temp file is written or the core
// is spawned. This is a whitelist, not a blacklist: external_ui, cache_file,
// rule_set, log.output, *_path, and any future option with filesystem or
// network side effects are refused because they are not listed - no per-field
// blocklist to maintain or bypass.
//
// If a legitimate client feature later needs a new option, extend the schema
// here consciously, not by loosening the validator.
func ValidateConfigJSON(data []byte) error {
	if len(data) == 0 {
		return fmt.Errorf("config is empty")
	}
	if len(data) > maxConfigBytes {
		return fmt.Errorf("config is %d bytes, limit is %d", len(data), maxConfigBytes)
	}
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.UseNumber()
	var doc any
	if err := dec.Decode(&doc); err != nil {
		return fmt.Errorf("config is not valid JSON: %w", err)
	}
	if dec.More() {
		return fmt.Errorf("config contains trailing data after the JSON document")
	}
	root, ok := doc.(map[string]any)
	if !ok {
		return fmt.Errorf("config root must be a JSON object")
	}
	if err := validateAgainst(root, configSchema); err != nil {
		return err
	}
	return validateConfigSemantics(root)
}

const (
	maxConfigBytes = 256 << 10 // 256 KiB
	maxListItems   = 32
)

var (
	secretPattern  = regexp.MustCompile(`^[A-Za-z0-9]{16,64}$`)
	uuidPattern    = regexp.MustCompile(`^[0-9a-fA-F-]{16,64}$`)
	tagPattern     = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,32}$`)
	ifacePattern   = regexp.MustCompile(`^[a-zA-Z0-9._-]{1,32}$`)
	warnLevelEnum  = []string{"debug", "info", "warn", "error", "silent"}
	sniffFpEnum    = []string{"chrome", "firefox", "edge", "safari", "ios", "android", "random", "randomized"}
	rejectMethods  = []string{"default", "drop"}
	stackEnum      = []string{"system", "gvisor", "mixed"}
	wireguardTypes = []string{"wireguard"}
	proxyTypes     = []string{"vless", "trojan", "hysteria2"}
)

// --- primitive validators -------------------------------------------------

func strSchema(maxLen int, enum []string, extra func(string) error) *schema {
	return &schema{kind: kStr, maxLen: maxLen, enum: enum, extraStr: extra}
}

func intSchema(min, max int64) *schema {
	return &schema{kind: kInt, min: min, max: max}
}

func objSchema(required []string, props map[string]*schema) *schema {
	return &schema{kind: kObject, required: required, props: props}
}

func arrSchema(item *schema, maxItems int) *schema {
	return &schema{kind: kArr, item: item, maxItems: maxItems}
}

func boolSchema() *schema { return &schema{kind: kBool} }

// validDomainish accepts a hostname or a domain_suffix entry (optionally
// leading dot). It rejects URLs, paths, whitespace and control characters.
func validDomainish(s string) error {
	if s == "" || len(s) > 253 {
		return fmt.Errorf("invalid domain %q", s)
	}
	bare := strings.TrimPrefix(s, ".")
	if bare == "" {
		return fmt.Errorf("invalid domain %q", s)
	}
	for _, label := range strings.Split(bare, ".") {
		if label == "" || len(label) > 63 {
			return fmt.Errorf("invalid domain label in %q", s)
		}
		for _, r := range label {
			switch {
			case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			default:
				return fmt.Errorf("invalid character %q in domain %q", string(r), s)
			}
		}
	}
	return nil
}

// validHost accepts an IP literal or a plain hostname - never a URL, a path
// or a value containing a scheme separator, so it can only ever be used for
// dialing and cannot smuggle file paths or options.
func validHost(s string) error {
	if s == "" || len(s) > 253 {
		return fmt.Errorf("invalid server host %q", s)
	}
	if strings.ContainsAny(s, "/\\:?#@") && !strings.HasPrefix(s, "[") {
		return fmt.Errorf("server host %q must be an IP or hostname, not a URL or path", s)
	}
	if strings.HasPrefix(s, "[") {
		if !strings.HasSuffix(s, "]") {
			return fmt.Errorf("invalid bracketed IPv6 host %q", s)
		}
		addr, err := netip.ParseAddr(strings.Trim(s, "[]"))
		if err != nil || !addr.Is6() {
			return fmt.Errorf("invalid bracketed IPv6 host %q", s)
		}
		return nil
	}
	if err := validDomainish(s); err != nil {
		return err
	}
	return nil
}

func validCIDR(s string) error {
	if _, err := netip.ParsePrefix(s); err != nil {
		return fmt.Errorf("invalid CIDR %q", s)
	}
	return nil
}

func validTag(s string) error {
	if !tagPattern.MatchString(s) {
		return fmt.Errorf("invalid tag %q", s)
	}
	return nil
}

func validIfaceName(s string) error {
	if !ifacePattern.MatchString(s) {
		return fmt.Errorf("invalid interface name %q", s)
	}
	return nil
}

// --- recursive walker -------------------------------------------------------

type schemaKind int

const (
	kObject schemaKind = iota
	kArr
	kStr
	kInt
	kBool
)

type schema struct {
	kind     schemaKind
	props    map[string]*schema
	required []string
	item     *schema
	maxItems int
	maxLen   int
	enum     []string
	min, max int64
	extraStr func(string) error
}

func validateAgainst(v any, s *schema) error {
	switch s.kind {
	case kObject:
		m, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("expected object, got %T", v)
		}
		seen := make(map[string]bool, len(m))
		for key := range m {
			child, allowed := s.props[key]
			if !allowed {
				return fmt.Errorf("field %q is not allowed", key)
			}
			seen[key] = true
			if err := validateAgainst(m[key], child); err != nil {
				return fmt.Errorf("%s: %w", key, err)
			}
		}
		for _, req := range s.required {
			if !seen[req] {
				return fmt.Errorf("missing required field %q", req)
			}
		}
		return nil
	case kArr:
		list, ok := v.([]any)
		if !ok {
			return fmt.Errorf("expected array, got %T", v)
		}
		limit := s.maxItems
		if limit == 0 {
			limit = maxListItems
		}
		if len(list) > limit {
			return fmt.Errorf("array has %d items, limit is %d", len(list), limit)
		}
		for i, item := range list {
			if err := validateAgainst(item, s.item); err != nil {
				return fmt.Errorf("[%d]: %w", i, err)
			}
		}
		return nil
	case kStr:
		str, ok := v.(string)
		if !ok {
			return fmt.Errorf("expected string, got %T", v)
		}
		maxLen := s.maxLen
		if maxLen == 0 {
			maxLen = 256
		}
		if len(str) > maxLen {
			return fmt.Errorf("string exceeds %d bytes", maxLen)
		}
		if s.enum != nil {
			for _, e := range s.enum {
				if e == str {
					return nil
				}
			}
			return fmt.Errorf("value %q is not one of the allowed options", str)
		}
		if s.extraStr != nil {
			return s.extraStr(str)
		}
		return nil
	case kInt:
		n, ok := v.(json.Number)
		if !ok {
			return fmt.Errorf("expected number, got %T", v)
		}
		var i int64
		if _, err := fmt.Sscan(n.String(), &i); err != nil {
			return fmt.Errorf("invalid integer %q", n.String())
		}
		if i < s.min || i > s.max {
			return fmt.Errorf("value %d out of range [%d,%d]", i, s.min, s.max)
		}
		return nil
	case kBool:
		if _, ok := v.(bool); !ok {
			return fmt.Errorf("expected boolean, got %T", v)
		}
		return nil
	}
	return fmt.Errorf("internal schema error")
}

// --- document schema (mirror of SingboxConfigBuilder output) ----------------

var tlsSchema = objSchema([]string{"enabled"}, map[string]*schema{
	"enabled":     boolSchema(),
	"server_name": strSchema(253, nil, validHost),
	"utls": objSchema([]string{"enabled"}, map[string]*schema{
		"enabled":     boolSchema(),
		"fingerprint": strSchema(32, sniffFpEnum, nil),
	}),
	"reality": objSchema([]string{"enabled", "public_key", "short_id"}, map[string]*schema{
		"enabled":    boolSchema(),
		"public_key": strSchema(128, nil, nil),
		"short_id":   strSchema(64, nil, nil),
	}),
})

var vlessSchema = objSchema([]string{"type", "tag", "server", "server_port", "uuid", "tls"}, map[string]*schema{
	"type":        strSchema(16, []string{"vless"}, nil),
	"tag":         strSchema(32, nil, validTag),
	"server":      strSchema(253, nil, validHost),
	"server_port": intSchema(1, 65535),
	"uuid": strSchema(64, nil, func(s string) error {
		if !uuidPattern.MatchString(s) {
			return fmt.Errorf("invalid uuid")
		}
		return nil
	}),
	"flow":            strSchema(32, []string{"", "xtls-rprx-vision"}, nil),
	"tls":             tlsSchema,
	"packet_encoding": strSchema(16, []string{"xudp", "packetaddr"}, nil),
})

var trojanSchema = objSchema([]string{"type", "tag", "server", "server_port", "password", "tls"}, map[string]*schema{
	"type":        strSchema(16, []string{"trojan"}, nil),
	"tag":         strSchema(32, nil, validTag),
	"server":      strSchema(253, nil, validHost),
	"server_port": intSchema(1, 65535),
	"password":    strSchema(256, nil, nil),
	"tls":         tlsSchema,
	"multiplex": objSchema([]string{"enabled"}, map[string]*schema{
		"enabled":         boolSchema(),
		"max_connections": intSchema(1, 64),
		"min_streams":     intSchema(1, 64),
		"padding":         boolSchema(),
	}),
})

var hysteria2Schema = objSchema([]string{"type", "tag", "server", "server_port", "password", "tls"}, map[string]*schema{
	"type":        strSchema(16, []string{"hysteria2"}, nil),
	"tag":         strSchema(32, nil, validTag),
	"server":      strSchema(253, nil, validHost),
	"server_port": intSchema(1, 65535),
	"password":    strSchema(256, nil, nil),
	"tls": objSchema([]string{"enabled"}, map[string]*schema{
		"enabled":     boolSchema(),
		"server_name": strSchema(253, nil, validHost),
	}),
	"obfs": objSchema([]string{"type", "password"}, map[string]*schema{
		"type":     strSchema(16, []string{"salamander"}, nil),
		"password": strSchema(256, nil, nil),
	}),
	"up_mbps":   intSchema(0, 1000000),
	"down_mbps": intSchema(0, 1000000),
})

var wireguardEndpointSchema = objSchema([]string{"type", "tag", "address", "private_key", "peers"}, map[string]*schema{
	"type":        strSchema(16, wireguardTypes, nil),
	"tag":         strSchema(32, nil, validTag),
	"system":      boolSchema(),
	"mtu":         intSchema(576, 65535),
	"address":     arrSchema(strSchema(64, nil, validCIDR), 4),
	"private_key": strSchema(128, nil, nil),
	"peers": arrSchema(objSchema([]string{"address", "port", "public_key"}, map[string]*schema{
		"address":                       strSchema(253, nil, validHost),
		"port":                          intSchema(1, 65535),
		"public_key":                    strSchema(128, nil, nil),
		"reserved":                      arrSchema(intSchema(0, 255), 3),
		"allowed_ips":                   arrSchema(strSchema(64, nil, validCIDR), 8),
		"persistent_keepalive_interval": intSchema(0, 65535),
	}), 2),
})

var dnsServerSchema = objSchema([]string{"type", "tag"}, map[string]*schema{
	"type":   strSchema(16, []string{"udp", "local"}, nil),
	"tag":    strSchema(32, nil, validTag),
	"server": strSchema(253, nil, validHost),
	"detour": strSchema(32, nil, validTag),
})

var dnsRuleSchema = objSchema([]string{"domain_suffix", "server"}, map[string]*schema{
	"domain_suffix": arrSchema(strSchema(253, nil, validDomainish), maxListItems),
	"server":        strSchema(32, nil, validTag),
})

var routeRuleSchema = objSchema(nil, map[string]*schema{
	// {"action":"sniff"}
	"action":   strSchema(16, []string{"sniff", "hijack-dns", "reject", "route"}, nil),
	"protocol": strSchema(16, []string{"dns"}, nil),
	// {"inbound":[...],"ip_cidr":[...],"action":"reject","method":"drop"}
	"inbound": arrSchema(strSchema(32, nil, validTag), 8),
	"ip_cidr": arrSchema(strSchema(64, nil, validCIDR), 8),
	"method":  strSchema(8, rejectMethods, nil),
	// {"ip_is_private":true,"outbound":"direct"} / {"domain_suffix":[...],"outbound":"direct"}
	"ip_is_private": boolSchema(),
	"domain_suffix": arrSchema(strSchema(253, nil, validDomainish), maxListItems),
	"outbound":      strSchema(32, nil, validTag),
})

var configSchema = objSchema(nil, map[string]*schema{
	"log": objSchema(nil, map[string]*schema{
		"level":     strSchema(8, warnLevelEnum, nil),
		"timestamp": boolSchema(),
	}),
	"experimental": objSchema(nil, map[string]*schema{
		"clash_api": objSchema([]string{"external_controller", "secret"}, map[string]*schema{
			"external_controller": strSchema(64, nil, func(s string) error {
				host, portStr, err := net.SplitHostPort(s)
				if err != nil || host != "127.0.0.1" {
					return fmt.Errorf("external_controller must be 127.0.0.1:<port>")
				}
				port, err := strconv.Atoi(portStr)
				if err != nil || port < 1024 || port > 65535 {
					return fmt.Errorf("external_controller port must be between 1024 and 65535")
				}
				return nil
			}),
			"secret": strSchema(64, nil, func(s string) error {
				if !secretPattern.MatchString(s) {
					return fmt.Errorf("clash secret must be 16-64 alphanumeric characters")
				}
				return nil
			}),
		}),
	}),
	"dns": objSchema([]string{"servers", "final"}, map[string]*schema{
		"servers":  arrSchema(dnsServerSchema, 4),
		"rules":    arrSchema(dnsRuleSchema, 16),
		"final":    strSchema(32, nil, validTag),
		"strategy": strSchema(16, []string{"ipv4_only", "prefer_ipv4", "prefer_ipv6", ""}, nil),
	}),
	"inbounds": arrSchema(objSchema([]string{"type", "tag"}, map[string]*schema{
		"type":              strSchema(16, []string{"tun", "mixed"}, nil),
		"listen":            strSchema(16, []string{"127.0.0.1"}, nil),
		"listen_port":       intSchema(1024, 65535),
		"tag":               strSchema(32, nil, validTag),
		"interface_name":    strSchema(32, nil, validIfaceName),
		"address":           arrSchema(strSchema(64, nil, validCIDR), 4),
		"auto_route":        boolSchema(),
		"strict_route":      boolSchema(),
		"stack":             strSchema(8, stackEnum, nil),
		"exclude_interface": arrSchema(strSchema(32, nil, validIfaceName), 8),
	}), 2),
	"outbounds": arrSchema(objSchema(nil, map[string]*schema{
		"type":            strSchema(16, append(proxyTypes, "direct"), nil),
		"tag":             strSchema(32, nil, validTag),
		"server":          strSchema(253, nil, validHost),
		"server_port":     intSchema(1, 65535),
		"uuid":            strSchema(64, nil, nil),
		"flow":            strSchema(32, []string{"", "xtls-rprx-vision"}, nil),
		"password":        strSchema(256, nil, nil),
		"tls":             tlsSchema,
		"multiplex":       trojanSchema.props["multiplex"],
		"packet_encoding": strSchema(16, []string{"xudp", "packetaddr"}, nil),
		"obfs":            hysteria2Schema.props["obfs"],
		"up_mbps":         intSchema(0, 1000000),
		"down_mbps":       intSchema(0, 1000000),
	}), 4),
	"endpoints": arrSchema(wireguardEndpointSchema, 2),
	"route": objSchema([]string{"rules", "final"}, map[string]*schema{
		"default_domain_resolver": strSchema(32, nil, validTag),
		"rules":                   arrSchema(routeRuleSchema, 16),
		"final":                   strSchema(32, nil, validTag),
		"auto_detect_interface":   boolSchema(),
	}),
})

// validateConfigSemantics enforces cross-field invariants the structural
// schema cannot express: fixed outbound shapes and referential integrity of
// every tag the config mentions.
func validateConfigSemantics(root map[string]any) error {
	// A config may use a TUN, a loopback HTTP/SOCKS proxy, or both. The
	// combined form is used on mobile platforms where the OS proxy setting is
	// advisory and the VPN TUN remains the traffic fallback.
	inbounds, _ := root["inbounds"].([]any)
	if len(inbounds) < 1 || len(inbounds) > 2 {
		return fmt.Errorf("one or two inbounds are required, got %d", len(inbounds))
	}
	inboundTags := make(map[string]bool, len(inbounds))
	hasTun, hasMixed := false, false
	for _, raw := range inbounds {
		inbound, ok := raw.(map[string]any)
		if !ok {
			return fmt.Errorf("inbound must be an object")
		}
		if inbound["type"] == "mixed" {
			if hasMixed || inbound["tag"] != "mixed-in" || inbound["listen"] != "127.0.0.1" || inbound["listen_port"] == nil {
				return fmt.Errorf("system proxy requires one loopback mixed-in listener and a port")
			}
			hasMixed = true
			for key := range inbound {
				if key != "type" && key != "tag" && key != "listen" && key != "listen_port" {
					return fmt.Errorf("field %q is not allowed on the mixed inbound", key)
				}
			}
			if exp, _ := root["experimental"].(map[string]any); exp != nil {
				if api, _ := exp["clash_api"].(map[string]any); api != nil {
					_, port, _ := net.SplitHostPort(api["external_controller"].(string))
					if inbound["listen_port"].(json.Number).String() == port {
						return fmt.Errorf("mixed listener and controller must use distinct ports")
					}
				}
			}
		} else {
			if hasTun || inbound["tag"] != "tun-in" || inbound["listen"] != nil || inbound["listen_port"] != nil {
				return fmt.Errorf(`the tun inbound tag must be "tun-in" and cannot set a proxy listener`)
			}
			hasTun = true
		}
		tag, _ := inbound["tag"].(string)
		inboundTags[tag] = true
	}
	if !hasTun && !hasMixed {
		return fmt.Errorf("at least one supported inbound is required")
	}

	// Outbounds: either proxy+direct, or a single direct (WireGuard endpoint
	// mode). No additional outbound may be smuggled in.
	outbounds, _ := root["outbounds"].([]any)
	endpoints, _ := root["endpoints"].([]any)
	switch len(outbounds) {
	case 1:
		only, ok := outbounds[0].(map[string]any)
		if !ok || only["tag"] != "direct" || only["type"] != "direct" {
			return fmt.Errorf(`a single outbound must be the {"type":"direct","tag":"direct"} outbound`)
		}
		if len(endpoints) == 0 {
			return fmt.Errorf("single direct outbound requires a wireguard endpoint")
		}
	case 2:
		first, ok := outbounds[0].(map[string]any)
		if !ok || first["tag"] != "proxy" {
			return fmt.Errorf(`the first outbound must have tag "proxy"`)
		}
		last, ok := outbounds[1].(map[string]any)
		if !ok || last["tag"] != "direct" || last["type"] != "direct" {
			return fmt.Errorf(`the last outbound must be the {"type":"direct","tag":"direct"} outbound`)
		}
		if len(endpoints) > 0 {
			return fmt.Errorf("wireguard endpoint cannot coexist with a proxy outbound")
		}
	default:
		return fmt.Errorf("expected 1-2 outbounds, got %d", len(outbounds))
	}
	for _, ep := range endpoints {
		epMap, ok := ep.(map[string]any)
		if !ok || epMap["tag"] != "proxy" {
			return fmt.Errorf(`every endpoint must have tag "proxy"`)
		}
	}

	// Referential integrity: collect the tags this config actually defines,
	// then require every reference (detour, dns server, route final, route
	// rule inbound/outbound) to resolve to one of them.
	knownTags := map[string]bool{"proxy": true, "direct": true}
	dnsMap, _ := root["dns"].(map[string]any)
	for _, srv := range toList(dnsMap["servers"]) {
		if m, ok := srv.(map[string]any); ok {
			if tag, _ := m["tag"].(string); tag != "" {
				knownTags[tag] = true
			}
		}
	}
	checkRef := func(where, value string, valid map[string]bool) error {
		if !valid[value] {
			return fmt.Errorf("%s references unknown tag %q", where, value)
		}
		return nil
	}
	for _, srv := range toList(dnsMap["servers"]) {
		m, ok := srv.(map[string]any)
		if !ok {
			continue
		}
		if detour, _ := m["detour"].(string); detour != "" {
			if err := checkRef("dns server detour", detour, knownTags); err != nil {
				return err
			}
		}
	}
	if final, _ := dnsMap["final"].(string); final != "" {
		if err := checkRef("dns.final", final, knownTags); err != nil {
			return err
		}
	}
	for _, rule := range toList(dnsMap["rules"]) {
		m, _ := rule.(map[string]any)
		if m == nil {
			continue
		}
		if server, _ := m["server"].(string); server != "" {
			if err := checkRef("dns rule", server, knownTags); err != nil {
				return err
			}
		}
	}
	route, _ := root["route"].(map[string]any)
	if route == nil {
		return fmt.Errorf("route object is required")
	}
	if final, _ := route["final"].(string); final != "proxy" {
		return fmt.Errorf(`route.final must be "proxy"`)
	}
	if resolver, _ := route["default_domain_resolver"].(string); resolver != "" {
		if err := checkRef("default_domain_resolver", resolver, knownTags); err != nil {
			return err
		}
	}
	for _, rule := range toList(route["rules"]) {
		m, _ := rule.(map[string]any)
		if m == nil {
			continue
		}
		for _, inb := range toList(m["inbound"]) {
			name, _ := inb.(string)
			if err := checkRef("route rule inbound", name, inboundTags); err != nil {
				return err
			}
		}
		if outbound, _ := m["outbound"].(string); outbound != "" {
			if err := checkRef("route rule outbound", outbound, map[string]bool{"direct": true, "proxy": true}); err != nil {
				return err
			}
		}
	}
	return nil
}

func toList(v any) []any {
	list, _ := v.([]any)
	return list
}
