package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestParseServiceCommand(t *testing.T) {
	tests := []struct {
		args    []string
		wantCmd string
		wantErr bool
	}{
		{[]string{"vpn-daemon.exe"}, "", false},
		{[]string{"vpn-daemon.exe", "service", "install"}, "install", false},
		{[]string{"vpn-daemon.exe", "service", "-install"}, "install", false},
		{[]string{"vpn-daemon.exe", "service", "--install"}, "install", false},
		{[]string{"vpn-daemon.exe", "service", "/install"}, "install", false},
		{[]string{"vpn-daemon.exe", "service", "start"}, "start", false},
		{[]string{"vpn-daemon.exe", "service", "stop"}, "stop", false},
		{[]string{"vpn-daemon.exe", "service", "uninstall"}, "uninstall", false},
		{[]string{"vpn-daemon.exe", "install"}, "install", false},
		{[]string{"vpn-daemon.exe", "-install"}, "install", false},
		{[]string{"vpn-daemon.exe", "/install"}, "install", false},
		{[]string{"vpn-daemon.exe", "start"}, "start", false},
		{[]string{"vpn-daemon.exe", "stop"}, "stop", false},
		{[]string{"vpn-daemon.exe", "uninstall"}, "uninstall", false},
		{[]string{"vpn-daemon.exe", "-service", "start"}, "start", false},
		{[]string{"vpn-daemon.exe", "--service", "start"}, "start", false},
		{[]string{"vpn-daemon.exe", "version"}, "version", false},
		{[]string{"vpn-daemon.exe", "-v"}, "version", false},
		{[]string{"vpn-daemon.exe", "--version"}, "version", false},
		{[]string{"vpn-daemon.exe", "help"}, "help", false},
		{[]string{"vpn-daemon.exe", "-h"}, "help", false},
		{[]string{"vpn-daemon.exe", "--help"}, "help", false},
		{[]string{"vpn-daemon.exe", "service"}, "", true},
		{[]string{"vpn-daemon.exe", "service", "invalid"}, "", true},
		{[]string{"vpn-daemon.exe", "invalid_cmd"}, "", true},
	}

	for _, tc := range tests {
		cmd, err := parseServiceCommand(tc.args)
		if (err != nil) != tc.wantErr {
			t.Errorf("parseServiceCommand(%v) err = %v, wantErr %v", tc.args, err, tc.wantErr)
		}
		if cmd != tc.wantCmd {
			t.Errorf("parseServiceCommand(%v) cmd = %v, wantCmd %v", tc.args, cmd, tc.wantCmd)
		}
	}
}

func TestOriginAllowed(t *testing.T) {
	// Legitimate localhost origins
	allowedOrigins := []string{
		"",
		"http://127.0.0.1:9527",
		"http://127.0.0.1:8080",
		"http://127.0.0.1",
		"http://localhost:8080",
		"http://localhost:3000",
		"https://localhost",
		"http://[::1]:9527",
		"http://[::1]",
	}
	for _, o := range allowedOrigins {
		if !isOriginAllowed(o) {
			t.Errorf("Expected origin %q to be allowed, but was rejected", o)
		}
	}

	// Malicious / spoofed origins that MUST be rejected
	rejectedOrigins := []string{
		"http://evil.com",
		"https://attacker.org",
		"http://localhost.attacker.com",
		"http://localhost.evil.com:9527",
		"http://127.0.0.1.attacker.com",
		"http://127.0.0.1.nip.io",
		"http://localhost-evil.com",
		"http://notlocalhost",
		"null",
		"file:///",
		"javascript:alert(1)",
	}
	for _, o := range rejectedOrigins {
		if isOriginAllowed(o) {
			t.Errorf("Security vulnerability: Expected origin %q to be REJECTED, but was allowed", o)
		}
	}
}

func TestHostAllowed(t *testing.T) {
	allowedHosts := []string{
		"",
		"127.0.0.1:9527",
		"localhost:9527",
		"127.0.0.1",
		"localhost",
		"[::1]:9527",
		"::1",
		"[::1]",
	}
	for _, h := range allowedHosts {
		if !isHostAllowed(h) {
			t.Errorf("Expected host %q to be allowed, but was rejected", h)
		}
	}

	rejectedHosts := []string{
		"evil.com:9527",
		"attacker.org",
		"localhost.evil.com",
		"127.0.0.1.nip.io",
		"localhost:evil.com",
		"8.8.8.8",
	}
	for _, h := range rejectedHosts {
		if isHostAllowed(h) {
			t.Errorf("Security vulnerability: Expected host %q to be REJECTED, but was allowed", h)
		}
	}
}

func TestIpcTokenGenerationAndAuth(t *testing.T) {
	// The disk-provisioning path requires SYSTEM/administrator rights by
	// design (the profile directory denies the installing user write access,
	// see TestIpcTokenFileAclDeniesUnprivilegedWrite), so the auth logic is
	// exercised through the documented AEROVPN_IPC_TOKEN development override
	// instead of writing into the real user profile.
	t.Setenv("AEROVPN_IPC_TOKEN", strings.Repeat("ab", 32))
	daemonAuthToken = ""
	defer func() { daemonAuthToken = "" }()

	tok := getOrInitIpcToken()
	if len(tok) < 16 {
		t.Fatalf("expected token length >= 16, got %d", len(tok))
	}
	// Calling again should return the same token
	tok2 := getOrInitIpcToken()
	if tok != tok2 {
		t.Fatalf("expected persistent token, got %s vs %s", tok, tok2)
	}

	// Test 1: Valid X-AeroVPN-Token header
	req1 := httptest.NewRequest(http.MethodPost, "/tunnel/start", nil)
	req1.Header.Set("X-AeroVPN-Token", tok)
	if !verifyIpcAuth(req1) {
		t.Errorf("verifyIpcAuth rejected valid X-AeroVPN-Token")
	}

	// Test 2: Valid Authorization Bearer header
	req2 := httptest.NewRequest(http.MethodPost, "/tunnel/start", nil)
	req2.Header.Set("Authorization", "Bearer "+tok)
	if !verifyIpcAuth(req2) {
		t.Errorf("verifyIpcAuth rejected valid Authorization Bearer header")
	}

	// Test 3: Invalid token
	req3 := httptest.NewRequest(http.MethodPost, "/tunnel/start", nil)
	req3.Header.Set("X-AeroVPN-Token", "invalid_token_123456789")
	if verifyIpcAuth(req3) {
		t.Errorf("verifyIpcAuth allowed invalid token")
	}

	// Test 4: Missing token
	req4 := httptest.NewRequest(http.MethodPost, "/tunnel/start", nil)
	if verifyIpcAuth(req4) {
		t.Errorf("verifyIpcAuth allowed unauthenticated request")
	}

	// Test 5: Missing token but with X-AeroVPN-Client assertion (backdoor probe)
	req5 := httptest.NewRequest(http.MethodPost, "/tunnel/start", nil)
	req5.Header.Set("X-AeroVPN-Client", "1")
	if verifyIpcAuth(req5) {
		t.Errorf("Security vulnerability: verifyIpcAuth allowed request with only X-AeroVPN-Client header without valid token")
	}

	// Test 6: fail-closed - with no token provisionable, every request is rejected
	daemonAuthToken = ""
	t.Setenv("AEROVPN_IPC_TOKEN", "")
	req6 := httptest.NewRequest(http.MethodPost, "/tunnel/start", nil)
	if verifyIpcAuth(req6) {
		t.Errorf("verifyIpcAuth allowed a request while no token could be provisioned")
	}
}

// TestIpcTokenFileAclDeniesUnprivilegedWrite pins the privilege invariant of
// the IPC token store: only SYSTEM/administrators may write the token file;
// the profile directory grants the installing user read+execute only (GRGX),
// so a plain-user process cannot tamper with or rotate the token.
func TestIpcTokenFileAclDeniesUnprivilegedWrite(t *testing.T) {
	if windows.GetCurrentProcessToken().IsElevated() {
		t.Skip("running elevated: the ACL denial under test only applies to unprivileged callers")
	}
	profile := t.TempDir()
	sid, err := currentProcessSID()
	if err != nil {
		t.Fatalf("currentProcessSID: %v", err)
	}
	localDataHandle, err := openIpcDirectory(profile)
	if err != nil {
		t.Fatalf("openIpcDirectory: %v", err)
	}
	defer windows.CloseHandle(localDataHandle)
	dh, err := createSecureIpcDirectory(localDataHandle, ipcTokenSubDir, sid)
	if err != nil {
		t.Fatalf("createSecureIpcDirectory: %v", err)
	}
	defer windows.CloseHandle(dh)

	err = writeIpcToken(profile, sid, strings.Repeat("cd", 32))
	if err == nil {
		t.Fatal("unprivileged caller was able to write the IPC token file; the directory ACL must deny it")
	}
}

// startAuxProcess starts a real helper process so exec.Cmd.Wait behaves as it
// does for sing-box. ping is present on every Windows host this package
// targets; the process is killed on cleanup if it is still running.
func startAuxProcess(t *testing.T, count string) *exec.Cmd {
	t.Helper()
	cmd := exec.Command("ping", "-n", count, "127.0.0.1")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start ping helper process: %v", err)
	}
	t.Cleanup(func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
			_, _ = cmd.Process.Wait()
		}
	})
	return cmd
}

func writeTempConfig(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "aerovpn_runtime_test.json")
	if err := os.WriteFile(path, []byte(`{"test":true}`), 0600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	return path
}

// TestMonitorCoreProcessIgnoresStaleGeneration pins the stop/start race fix:
// a monitor goroutine whose generation was superseded must leave every piece
// of manager state untouched, including the newer generation's stats channel,
// status and runtime config file. It must still settle its own done channel.
func TestMonitorCoreProcessIgnoresStaleGeneration(t *testing.T) {
	m := &TunnelManager{runID: 2, status: StatusConnected}
	stopStats := make(chan struct{})
	cfgPath := writeTempConfig(t)
	m.stopStats = stopStats
	m.configPath = cfgPath

	done := make(chan struct{})
	cmd := startAuxProcess(t, "1")
	m.monitorCoreProcess(cmd, 1, done) // gen 1 vs current runID 2: stale

	select {
	case <-stopStats:
		t.Error("stale monitor closed the newer generation's stats channel")
	default:
	}
	if m.status != StatusConnected {
		t.Errorf("stale monitor changed status to %v", m.status)
	}
	if m.configPath != cfgPath {
		t.Errorf("stale monitor changed configPath to %q", m.configPath)
	}
	if _, err := os.Stat(cfgPath); err != nil {
		t.Errorf("stale monitor removed the newer generation's config file: %v", err)
	}
	if m.runID != 2 {
		t.Errorf("stale monitor changed runID to %d", m.runID)
	}
	select {
	case <-done:
	default:
		t.Error("stale monitor must settle its own done channel")
	}
}

// TestMonitorCoreProcessSettlesOwnGeneration pins the normal single-generation
// path: the monitor of the current generation closes the stats channel,
// resets the status, removes the runtime config and settles done.
func TestMonitorCoreProcessSettlesOwnGeneration(t *testing.T) {
	m := &TunnelManager{runID: 5, status: StatusConnected}
	stopStats := make(chan struct{})
	cfgPath := writeTempConfig(t)
	m.stopStats = stopStats
	m.configPath = cfgPath

	done := make(chan struct{})
	cmd := startAuxProcess(t, "1")
	m.monitorCoreProcess(cmd, 5, done)

	if m.status != StatusDisconnected {
		t.Errorf("status = %v, want disconnected", m.status)
	}
	select {
	case <-stopStats:
	default:
		t.Error("stats channel was not closed")
	}
	if _, err := os.Stat(cfgPath); !os.IsNotExist(err) {
		t.Errorf("runtime config was not removed: %v", err)
	}
	select {
	case <-done:
	default:
		t.Error("done channel was not closed")
	}
}

// TestStopWaitsForMonitorGeneration pins that Stop() does not return before
// the current generation's monitor goroutine has settled, so a following
// Start() can never race it.
func TestStopWaitsForMonitorGeneration(t *testing.T) {
	m := &TunnelManager{
		runID:        7,
		status:       StatusConnected,
		stopStats:    make(chan struct{}),
		cancelTunnel: func() {},
	}
	cfgPath := writeTempConfig(t)
	m.configPath = cfgPath

	cmd := startAuxProcess(t, "30")
	m.singboxCmd = cmd
	done := make(chan struct{})
	m.monitorDone = done
	go m.monitorCoreProcess(cmd, 7, done)

	if err := m.Stop(); err != nil {
		t.Fatalf("Stop: %v", err)
	}

	select {
	case <-done:
	default:
		t.Fatal("Stop returned before the monitor goroutine settled this generation")
	}
	if m.status != StatusDisconnected {
		t.Errorf("status = %v, want disconnected", m.status)
	}
	if m.singboxCmd != nil {
		t.Error("Stop did not clear singboxCmd")
	}
	if _, err := os.Stat(cfgPath); !os.IsNotExist(err) {
		t.Errorf("runtime config was not removed: %v", err)
	}
}

func TestNtCreateIpcEntrySynchronize(t *testing.T) {
	dir := t.TempDir()
	dirHandle, err := openIpcDirectory(dir)
	if err != nil {
		t.Fatalf("openIpcDirectory: %v", err)
	}
	defer windows.CloseHandle(dirHandle)

	fileHandle, err := ntCreateIpcEntry(dirHandle, "test_token.txt",
		windows.GENERIC_WRITE|windows.FILE_READ_ATTRIBUTES|windows.DELETE|windows.SYNCHRONIZE,
		windows.FILE_SHARE_READ, windows.FILE_CREATE,
		windows.FILE_NON_DIRECTORY_FILE|windows.FILE_SYNCHRONOUS_IO_NONALERT|windows.FILE_WRITE_THROUGH, nil)
	if err != nil {
		t.Fatalf("ntCreateIpcEntry failed: %v", err)
	}
	defer windows.CloseHandle(fileHandle)

	data := []byte("hello-ipc")
	var written uint32
	if err := windows.WriteFile(fileHandle, data, &written, nil); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}
	if int(written) != len(data) {
		t.Fatalf("wrote %d bytes, want %d", written, len(data))
	}
}

func TestParseClashApiPort(t *testing.T) {
	tests := []struct {
		name string
		json string
		want int
	}{
		{
			name: "custom port",
			json: `{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9095"}}}`,
			want: 9095,
		},
		{
			name: "default port",
			json: `{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}}}`,
			want: 9090,
		},
		{
			name: "missing clash api",
			json: `{}`,
			want: DefaultClashApiPort,
		},
		{
			name: "invalid port string",
			json: `{"experimental":{"clash_api":{"external_controller":"127.0.0.1:abc"}}}`,
			want: DefaultClashApiPort,
		},
		{
			name: "port out of range",
			json: `{"experimental":{"clash_api":{"external_controller":"127.0.0.1:99999"}}}`,
			want: DefaultClashApiPort,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := parseClashApiPort(tc.json)
			if got != tc.want {
				t.Errorf("parseClashApiPort() = %d, want %d", got, tc.want)
			}
		})
	}
}
