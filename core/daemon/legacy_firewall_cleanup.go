package main

// Upgrade/uninstall recovery only. Windows no longer implements a Kill Switch.
// These helpers remove old AeroVPN rules and restore an existing saved baseline;
// they never capture a new baseline, add rules, or arm a blocking policy.
import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os/exec"
	"strings"
	"syscall"

	"golang.org/x/sys/windows/registry"
)

const (
	legacyFirewallRuleBlock     = "AeroVPN_KillSwitch_Block"
	legacyFirewallRuleAllow     = "AeroVPN_KillSwitch_Allow"
	legacyFirewallRuleAllowDNS  = "AeroVPN_KillSwitch_Allow_DNS"
	legacyFirewallRuleAllowDHCP = "AeroVPN_KillSwitch_Allow_DHCP"
	legacyFirewallRuleAllowAPI  = "AeroVPN_KillSwitch_Allow_API"
	legacyFirewallRuleAllowApps = "AeroVPN_KillSwitch_Allow_Apps"
	legacyFirewallRuleAllowCore = "AeroVPN_KillSwitch_Allow_Core"
	legacyFirewallRuleAllowTun  = "AeroVPN_KillSwitch_Allow_Tunnel"
	legacyFirewallBackupRegVal  = "FirewallDefaultOutboundBackup"
)

type firewallProfileState struct {
	Enabled               *bool  `json:"Enabled"`
	Name                  string `json:"Name"`
	DefaultOutboundAction string `json:"DefaultOutboundAction"`
}

func (s *firewallProfileState) UnmarshalJSON(data []byte) error {
	type rawState struct {
		Name                  string `json:"Name"`
		Enabled               any    `json:"Enabled"`
		DefaultOutboundAction any    `json:"DefaultOutboundAction"`
	}
	var raw rawState
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	s.Name = raw.Name
	switch v := raw.Enabled.(type) {
	case bool:
		s.Enabled = &v
	case float64:
		// Windows NetSecurity NetGPOProfileEnabled CIM enum: 1 = True/Enabled, 2 = False/Disabled
		b := (int(v) == 1)
		s.Enabled = &b
	case string:
		b := strings.EqualFold(v, "true") || v == "1"
		s.Enabled = &b
	}
	switch v := raw.DefaultOutboundAction.(type) {
	case string:
		s.DefaultOutboundAction = v
	case float64:
		// Windows NetSecurity NetGPOProfileOutboundAction CIM enum: 2 = Allow, 4 = Block
		switch int(v) {
		case 2:
			s.DefaultOutboundAction = "Allow"
		case 4:
			s.DefaultOutboundAction = "Block"
		default:
			s.DefaultOutboundAction = fmt.Sprintf("%d", int(v))
		}
	}
	return nil
}

// runFirewallCommand is used only by legacy policy recovery. Tests replace it
// to verify rule removal without touching the host firewall.
var runFirewallCommand = func(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

var firewallProfiles = map[string]bool{"Domain": true, "Private": true, "Public": true}

func queryFirewallProfiles(policyStore string) ([]firewallProfileState, error) {
	script := "$ErrorActionPreference='Stop'; Get-NetFirewallProfile -PolicyStore " + policyStore +
		" | Select-Object Name, @{N='Enabled';E={[bool]$_.Enabled}}, @{N='DefaultOutboundAction';E={[string]$_.DefaultOutboundAction}} | ConvertTo-Json -Compress"
	output, err := runFirewallCommand("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
	if err != nil {
		return nil, fmt.Errorf("query Windows Firewall profiles: %w: %s", err, strings.TrimSpace(string(output)))
	}
	var profiles []firewallProfileState
	if err := json.Unmarshal(output, &profiles); err != nil {
		var single firewallProfileState
		if singleErr := json.Unmarshal(output, &single); singleErr != nil || single.Name == "" {
			return nil, fmt.Errorf("decode Windows Firewall profile state: %w", err)
		}
		profiles = []firewallProfileState{single}
	}
	if err := validateFirewallProfiles(profiles); err != nil {
		return nil, err
	}
	return profiles, nil
}

func validateFirewallProfiles(profiles []firewallProfileState) error {
	if err := validateFirewallProfileUpdates(profiles); err != nil {
		return err
	}
	if len(profiles) != len(firewallProfiles) {
		return fmt.Errorf("Windows Firewall query returned %d profiles; expected %d", len(profiles), len(firewallProfiles))
	}
	return nil
}

func validateFirewallProfileUpdates(profiles []firewallProfileState) error {
	if len(profiles) == 0 {
		return fmt.Errorf("no Windows Firewall profiles were supplied")
	}
	seen := make(map[string]bool, len(profiles))
	for _, profile := range profiles {
		if !firewallProfiles[profile.Name] || seen[profile.Name] {
			return fmt.Errorf("unexpected or duplicate Windows Firewall profile %q", profile.Name)
		}
		if profile.Enabled == nil {
			return fmt.Errorf("Windows Firewall profile %s has no Enabled state", profile.Name)
		}
		action := strings.TrimSpace(profile.DefaultOutboundAction)
		if action != "Allow" && action != "Block" {
			return fmt.Errorf("unexpected outbound action %q for profile %s", action, profile.Name)
		}
		seen[profile.Name] = true
	}
	return nil
}

func readFirewallProfileBackup() ([]firewallProfileState, bool, error) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, ipcProfileRegKey, registry.QUERY_VALUE)
	if errors.Is(err, registry.ErrNotExist) || errors.Is(err, syscall.ERROR_PATH_NOT_FOUND) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("open Windows Firewall policy backup: %w", err)
	}
	defer key.Close()
	value, _, err := key.GetStringValue(legacyFirewallBackupRegVal)
	if errors.Is(err, registry.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("read Windows Firewall policy backup: %w", err)
	}
	var profiles []firewallProfileState
	if err := json.Unmarshal([]byte(value), &profiles); err != nil {
		return nil, false, fmt.Errorf("decode saved Windows Firewall policy: %w", err)
	}
	legacySnapshot := false
	for _, profile := range profiles {
		legacySnapshot = legacySnapshot || profile.Enabled == nil
	}
	if legacySnapshot {
		// Older builds saved the outbound action but never changed Enabled. Keep
		// the current enabled state while restoring the recorded outbound action.
		// Persist the upgraded snapshot so interrupted recovery remains retryable.
		current, err := queryFirewallProfiles("PersistentStore")
		if err != nil {
			return nil, false, fmt.Errorf("upgrade saved Windows Firewall policy: %w", err)
		}
		currentByName := make(map[string]firewallProfileState, len(current))
		for _, profile := range current {
			currentByName[profile.Name] = profile
		}
		for i := range profiles {
			if profiles[i].Enabled == nil {
				currentProfile, ok := currentByName[profiles[i].Name]
				if !ok || currentProfile.Enabled == nil {
					return nil, false, fmt.Errorf("could not recover enabled state for saved %s firewall profile", profiles[i].Name)
				}
				profiles[i].Enabled = currentProfile.Enabled
			}
		}
	}
	if err := validateFirewallProfiles(profiles); err != nil {
		return nil, false, fmt.Errorf("saved Windows Firewall policy is invalid: %w", err)
	}
	if legacySnapshot {
		if err := saveFirewallProfileBackup(profiles); err != nil {
			return nil, false, fmt.Errorf("upgrade saved Windows Firewall policy: %w", err)
		}
	}
	return profiles, true, nil
}

func saveFirewallProfileBackup(profiles []firewallProfileState) error {
	data, err := json.Marshal(profiles)
	if err != nil {
		return err
	}
	key, _, err := registry.CreateKey(registry.LOCAL_MACHINE, ipcProfileRegKey, registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("create Windows Firewall backup registry key: %w", err)
	}
	defer key.Close()
	if err := key.SetStringValue(legacyFirewallBackupRegVal, string(data)); err != nil {
		return fmt.Errorf("save Windows Firewall policy backup: %w", err)
	}
	return nil
}

func clearFirewallProfileBackup() error {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, ipcProfileRegKey, registry.SET_VALUE)
	if errors.Is(err, registry.ErrNotExist) || errors.Is(err, syscall.ERROR_PATH_NOT_FOUND) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("open Windows Firewall backup registry key: %w", err)
	}
	defer key.Close()
	if err := key.DeleteValue(legacyFirewallBackupRegVal); err != nil && !errors.Is(err, registry.ErrNotExist) {
		return fmt.Errorf("clear Windows Firewall policy backup: %w", err)
	}
	return nil
}

func setFirewallProfileStates(profiles []firewallProfileState) error {
	if err := validateFirewallProfileUpdates(profiles); err != nil {
		return err
	}
	for _, profile := range profiles {
		enabled := "False"
		if *profile.Enabled {
			enabled = "True"
		}
		script := "$ErrorActionPreference='Stop'; Set-NetFirewallProfile -PolicyStore PersistentStore -Profile " + profile.Name +
			" -Enabled " + enabled + " -DefaultOutboundAction " + profile.DefaultOutboundAction
		output, err := runFirewallCommand("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
		if err != nil {
			return fmt.Errorf("set %s Windows Firewall profile: %w: %s", profile.Name, err, strings.TrimSpace(string(output)))
		}
	}
	return nil
}

func restoreFirewallProfileBackup() error {
	profiles, exists, err := readFirewallProfileBackup()
	if err != nil || !exists {
		return err
	}
	current, err := queryFirewallProfiles("PersistentStore")
	if err != nil {
		return fmt.Errorf("inspect current Windows Firewall profile state before restore: %w", err)
	}
	currentByName := make(map[string]firewallProfileState, len(current))
	for _, profile := range current {
		currentByName[profile.Name] = profile
	}
	toRestore := make([]firewallProfileState, 0, len(profiles))
	for _, saved := range profiles {
		state, ok := currentByName[saved.Name]
		if !ok || state.Enabled == nil {
			return fmt.Errorf("could not inspect current %s Windows Firewall profile before restore", saved.Name)
		}
		if *state.Enabled && state.DefaultOutboundAction == "Block" {
			toRestore = append(toRestore, saved)
			continue
		}
		log.Printf("[LEGACY-CLEANUP] Preserving externally changed %s firewall profile (enabled=%t outbound=%s)",
			saved.Name, *state.Enabled, state.DefaultOutboundAction)
	}
	if len(toRestore) > 0 {
		if err := setFirewallProfileStates(toRestore); err != nil {
			return fmt.Errorf("restore Windows Firewall profile state: %w", err)
		}
	}
	if err := clearFirewallProfileBackup(); err != nil {
		return err
	}
	return nil
}

func removeLegacyFirewallRules() error {
	// Remove only these exact names written by old AeroVPN versions.
	// No current connection path creates firewall rules.
	rules := []string{
		legacyFirewallRuleBlock,
		legacyFirewallRuleAllow,
		legacyFirewallRuleAllowDNS,
		legacyFirewallRuleAllowDHCP,
		legacyFirewallRuleAllowAPI,
		legacyFirewallRuleAllowApps,
		legacyFirewallRuleAllowCore,
		legacyFirewallRuleAllowTun,
	}
	quotedRules := make([]string, 0, len(rules))
	for _, rule := range rules {
		quotedRules = append(quotedRules, "'"+rule+"'")
	}
	script := "$ErrorActionPreference='Stop'; $names=@(" + strings.Join(quotedRules, ",") + "); foreach($name in $names){ Get-NetFirewallRule -PolicyStore PersistentStore -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop }"
	output, err := runFirewallCommand("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
	if err != nil {
		return fmt.Errorf("remove AeroVPN Windows Firewall rules: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func cleanupLegacyFirewall() error {
	ruleErr := removeLegacyFirewallRules()
	policyErr := restoreFirewallProfileBackup()
	return errors.Join(ruleErr, policyErr)
}
