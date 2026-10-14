package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// Adapted from the old owned-rule coverage test. Recovery must only remove
// known AeroVPN names; it must never add rules or change profile defaults.
func TestLegacyFirewallRuleRemoval(t *testing.T) {
	original := runFirewallCommand
	defer func() { runFirewallCommand = original }()
	var script string
	runFirewallCommand = func(name string, args ...string) ([]byte, error) {
		if name != "powershell.exe" {
			t.Fatalf("unexpected command: %s", name)
		}
		script = strings.Join(args, " ")
		return nil, nil
	}
	if err := removeLegacyFirewallRules(); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{
		legacyFirewallRuleBlock, legacyFirewallRuleAllow, legacyFirewallRuleAllowDNS,
		legacyFirewallRuleAllowDHCP, legacyFirewallRuleAllowAPI, legacyFirewallRuleAllowApps,
		legacyFirewallRuleAllowCore, legacyFirewallRuleAllowTun,
	} {
		if !strings.Contains(script, "'"+name+"'") {
			t.Errorf("missing old rule: %s", name)
		}
	}
	if !strings.Contains(script, "Remove-NetFirewallRule") || strings.Contains(script, "New-NetFirewallRule") || strings.Contains(script, "Set-NetFirewallProfile") {
		t.Errorf("unexpected recovery command: %s", script)
	}
}

func TestFirewallProfileStateUnmarshalNumericEnums(t *testing.T) {
	// Tests that Windows CIM enum values (Enabled: 1/2, DefaultOutboundAction: 2/4)
	// produced by PowerShell 5.1 ConvertTo-Json are correctly unmarshaled.
	jsonInput := `[
		{"Name":"Domain","Enabled":1,"DefaultOutboundAction":2},
		{"Name":"Private","Enabled":2,"DefaultOutboundAction":4},
		{"Name":"Public","Enabled":true,"DefaultOutboundAction":"Block"}
	]`
	var profiles []firewallProfileState
	if err := json.Unmarshal([]byte(jsonInput), &profiles); err != nil {
		t.Fatalf("json.Unmarshal failed: %v", err)
	}
	if len(profiles) != 3 {
		t.Fatalf("got %d profiles, want 3", len(profiles))
	}
	if profiles[0].Enabled == nil || !*profiles[0].Enabled || profiles[0].DefaultOutboundAction != "Allow" {
		t.Errorf("profile 0: got enabled=%v action=%s, want true Allow", profiles[0].Enabled, profiles[0].DefaultOutboundAction)
	}
	if profiles[1].Enabled == nil || *profiles[1].Enabled || profiles[1].DefaultOutboundAction != "Block" {
		t.Errorf("profile 1: got enabled=%v action=%s, want false Block", profiles[1].Enabled, profiles[1].DefaultOutboundAction)
	}
	if profiles[2].Enabled == nil || !*profiles[2].Enabled || profiles[2].DefaultOutboundAction != "Block" {
		t.Errorf("profile 2: got enabled=%v action=%s, want true Block", profiles[2].Enabled, profiles[2].DefaultOutboundAction)
	}
}
