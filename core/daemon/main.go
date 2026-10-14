package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	ServiceName         = "AeroVpnDaemon"
	ServiceDisplayName  = "AeroVPN Privileged Helper Service"
	ServiceDescription  = "AeroVPN Privileged Daemon managing Wintun TUN adapter and sing-box core engine"
	Version             = "1.1.0"
	DefaultClashApiPort = 9090
)

type TunnelStatus string

const (
	StatusDisconnected TunnelStatus = "disconnected"
	StatusConnecting   TunnelStatus = "connecting"
	StatusConnected    TunnelStatus = "connected"
	StatusReconnecting TunnelStatus = "reconnecting"
	StatusError        TunnelStatus = "error"
)

// TunnelManager coordinates sing-box lifecycle and Wintun adapter.
type TunnelManager struct {
	lifecycleMu sync.Mutex // serializes start/stop across unlocked waits
	mu          sync.RWMutex
	status      TunnelStatus
	lastError   string
	activeSince time.Time
	assignedIp  string
	country     string
	city        string

	singboxCmd    *exec.Cmd
	configPath    string
	cancelTunnel  context.CancelFunc
	daemonDir     string
	singboxPath   string
	wintunDllPath string
	clashSecret   string
	clashPort     int
	proxyPort     int
	// Tunnel generation guarding the core-exit monitor against the stop/start
	// race: Stop() kills the process without waiting, so a later Start() can
	// replace the manager state before the old monitor goroutine wakes up.
	// runID is bumped on every Start attempt; a monitor whose generation no
	// longer matches must exit without touching any state. monitorDone is
	// closed by the current generation's monitor once it has settled, and
	// Stop() waits on it before returning.
	runID       uint64
	monitorDone chan struct{}

	// Real-time telemetry counters
	downBps   int64
	upBps     int64
	totalDown int64
	totalUp   int64
	stopStats chan struct{}
}

var manager *TunnelManager
var daemonAuthToken string
var daemonRunningAsService bool

type StartRequest struct {
	ConfigJson  string `json:"config_json"`
	AssignedIp  string `json:"assigned_ip"`
	Country     string `json:"country"`
	City        string `json:"city"`
	ClashSecret string `json:"clash_secret"`
}

type StatsResponse struct {
	Status      TunnelStatus `json:"status"`
	LastError   string       `json:"last_error,omitempty"`
	AssignedIp  string       `json:"assigned_ip,omitempty"`
	Country     string       `json:"country,omitempty"`
	City        string       `json:"city,omitempty"`
	UptimeSec   int64        `json:"uptime_sec"`
	DownlinkBps int64        `json:"downlink_bps"`
	UplinkBps   int64        `json:"uplink_bps"`
	TotalDown   int64        `json:"total_down_bytes"`
	TotalUp     int64        `json:"total_up_bytes"`
	Engine      string       `json:"engine"`
	// Informational only: modern sing-box embeds wintun.dll and loads it from
	// memory, so the presence of a dll file next to the daemon is not what
	// determines whether the adapter can be created.
	Wintun    bool `json:"wintun_loaded"`
	ProxyPort int  `json:"proxy_port"`
}

func findSingboxBinary(daemonDir string) string {
	candidates := []string{
		filepath.Join(daemonDir, "sing-box.exe"),
		filepath.Join(daemonDir, "bin", "sing-box.exe"),
		filepath.Join(daemonDir, "..", "..", "core", "bin", "sing-box.exe"),
		filepath.Join(os.Getenv("ProgramFiles"), "sing-box", "sing-box.exe"),
	}

	for _, p := range candidates {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p
		}
	}

	if p, err := exec.LookPath("sing-box.exe"); err == nil {
		return p
	}

	return filepath.Join(daemonDir, "sing-box.exe")
}

func NewTunnelManager() *TunnelManager {
	exePath, err := os.Executable()
	var daemonDir string
	if err == nil {
		daemonDir = filepath.Dir(exePath)
	} else {
		daemonDir, _ = os.Getwd()
	}

	sbPath := findSingboxBinary(daemonDir)
	wintunPath := filepath.Join(daemonDir, "wintun.dll")

	m := &TunnelManager{
		status:        StatusDisconnected,
		daemonDir:     daemonDir,
		singboxPath:   sbPath,
		wintunDllPath: wintunPath,
	}

	// Recover only remnants from older releases; this does not enable protection.
	if err := cleanupLegacyFirewall(); err != nil {
		log.Printf("[LEGACY-CLEANUP] Could not recover old firewall state: %v", err)
	}
	return m
}

func (m *TunnelManager) Start(req StartRequest) error {
	m.lifecycleMu.Lock()
	defer m.lifecycleMu.Unlock()
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.status == StatusConnected || m.status == StatusConnecting {
		return fmt.Errorf("tunnel already running or connecting")
	}
	// An aborted start can return before its monitor finishes. Settle it before
	// replacing config/stats ownership; release mu so that monitor can finish.
	if done := m.monitorDone; done != nil {
		m.mu.Unlock()
		<-done
		m.mu.Lock()
	}

	m.status = StatusConnecting
	m.lastError = ""
	m.assignedIp = req.AssignedIp
	m.country = req.Country
	m.city = req.City
	m.clashSecret = req.ClashSecret
	m.clashPort = parseClashApiPort(req.ConfigJson)
	atomic.StoreInt64(&m.downBps, 0)
	atomic.StoreInt64(&m.upBps, 0)

	// Generation token for this tunnel attempt: the core-exit monitor carries
	// it and verifies it before touching any state, so a monitor goroutine
	// from a killed tunnel can never clobber a newer generation (stop->start
	// race: Stop() kills without waiting).
	m.runID++
	gen := m.runID

	// Locate sing-box binary
	m.singboxPath = findSingboxBinary(m.daemonDir)
	if _, err := os.Stat(m.singboxPath); err != nil {
		m.status = StatusError
		m.lastError = fmt.Sprintf("Official sing-box core not found at %s. Please install sing-box.exe or run fetch_upstream_cores.ps1", m.singboxPath)
		return fmt.Errorf("%s", m.lastError)
	}

	// Privilege-boundary check: the config arrives over loopback IPC from an
	// unprivileged process, but it runs as SYSTEM. Reject anything outside the
	// exact whitelist of options the client's SingboxConfigBuilder may emit
	// (blocks external_ui downloads, cache_file/log.output/rule_set/*_path
	// filesystem access, and every other non-listed option) BEFORE the temp
	// file is written or the core is spawned. See config_guard.go for the
	// threat model.
	if err := ValidateConfigJSON([]byte(req.ConfigJson)); err != nil {
		m.status = StatusError
		m.lastError = fmt.Sprintf("config rejected: %v", err)
		return fmt.Errorf("%s", m.lastError)
	}
	m.proxyPort = parseSystemProxyPort(req.ConfigJson)

	// Write the runtime config to a temporary file, then validate it with the
	// official core before spawning anything (reuses upstream `sing-box check -c`
	// so invalid JSON never starts a tunnel).
	//
	// Secret hygiene: the config holds node credentials, so it must not sit
	// world-readable. os.CreateTemp lands in the SYSTEM account's temp directory
	// (C:\Windows\Temp by default), whose ACL is not readable by ordinary users -
	// that directory ACL, not the mode below, is the actual protection (on Windows
	// os.Chmod only toggles the read-only attribute and never touches the ACL).
	// The file is removed on stop and on core exit.
	tmpFile, err := os.CreateTemp("", "aerovpn_runtime_*.json")
	if err != nil {
		m.status = StatusError
		m.lastError = fmt.Sprintf("Failed to create runtime config file: %v", err)
		return err
	}
	// Meaningful on unix hosts; harmless no-op for ACLs on Windows.
	_ = os.Chmod(tmpFile.Name(), 0600)

	if _, err := tmpFile.WriteString(req.ConfigJson); err != nil {
		tmpFile.Close()
		os.Remove(tmpFile.Name())
		m.status = StatusError
		m.lastError = fmt.Sprintf("Failed to write runtime config: %v", err)
		return err
	}
	tmpFile.Close()

	// Upstream preflight: `sing-box check -c <config>` validates schema before `run`.
	// Directly reuses official core, no local reimplementation.
	if checkCmd := exec.Command(m.singboxPath, "check", "-c", tmpFile.Name()); checkCmd != nil {
		if out, err := checkCmd.CombinedOutput(); err != nil {
			os.Remove(tmpFile.Name())
			m.status = StatusError
			m.lastError = fmt.Sprintf("sing-box config check failed: %v: %s", err, string(out))
			return fmt.Errorf("%s", m.lastError)
		}
	}
	m.configPath = tmpFile.Name()

	ctx, cancel := context.WithCancel(context.Background())
	m.cancelTunnel = cancel

	// Launch sing-box run -c <configPath>
	cmd := exec.CommandContext(ctx, m.singboxPath, "run", "-c", m.configPath)
	cmd.Dir = m.daemonDir

	// Let os/exec drain stdout and stderr into the same writer. It creates
	// the pipe/copy goroutine and joins it in Wait(), avoiding both sequential
	// MultiReader deadlock and the StdoutPipe-vs-Wait close race (Go #60309).
	cmd.Stdout = coreLogWriter{}
	cmd.Stderr = cmd.Stdout
	cmd.WaitDelay = 2 * time.Second
	if err := cmd.Start(); err != nil {
		cancel()
		m.status = StatusError
		m.lastError = fmt.Sprintf("Failed to spawn sing-box core: %v", err)
		os.Remove(m.configPath)
		return err
	}
	m.singboxCmd = cmd
	m.status = StatusConnecting
	m.activeSince = time.Time{}
	m.stopStats = make(chan struct{})
	done := make(chan struct{})
	m.monitorDone = done
	log.Printf("[TUNNEL] Started sing-box process (PID: %d) with Wintun in %s", cmd.Process.Pid, m.daemonDir)

	// Start real telemetry poller from Clash API (authenticated when secret present)
	go m.pollRealTrafficStats(m.stopStats, req.ClashSecret, m.clashPort)
	go m.expireUnreadyCore(m.stopStats)

	// Monitor process lifecycle
	go m.monitorCoreProcess(cmd, gen, done)

	return nil
}

type coreLogWriter struct{}

func (m *TunnelManager) expireUnreadyCore(stopCh <-chan struct{}) {
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	select {
	case <-stopCh:
		return
	case <-timer.C:
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stopStats == stopCh && m.status == StatusConnecting {
		m.status = StatusError
		m.lastError = "Proxy core did not become ready within 15 seconds"
		if m.cancelTunnel != nil {
			m.cancelTunnel()
		}
	}
}

func (coreLogWriter) Write(content []byte) (int, error) {
	log.Printf("[CORE] %s", content)
	return len(content), nil
}

// monitorCoreProcess waits for the sing-box process of tunnel generation gen
// to exit and then settles that generation's state. Stop() kills the process
// without waiting for this goroutine, so a later Start() can race it: the
// generation token makes a stale goroutine observe-and-exit without touching
// any manager state, and Stop() waits on done before it returns so no stale
// goroutine outlives a completed stop.
func (m *TunnelManager) monitorCoreProcess(cmd *exec.Cmd, gen uint64, done chan struct{}) {
	defer close(done) // including stale generations and aborted starts
	err := cmd.Wait()

	m.mu.Lock()
	if m.runID != gen {
		// A newer generation owns the manager now (Stop followed by Start, or
		// an aborted start replaced by a retry). Everything this generation
		// could clean up has already been handled by Stop() or by the Start()
		// that superseded it.
		m.mu.Unlock()
		return
	}

	if m.stopStats != nil {
		close(m.stopStats)
		m.stopStats = nil
	}

	if m.status == StatusConnected || m.status == StatusConnecting {
		// Unexpected core exit: expose the stopped state and the process error.
		log.Printf("[TUNNEL] sing-box exited: %v", err)
		m.status = StatusDisconnected
		if err != nil {
			m.lastError = fmt.Sprintf("Core terminated: %v", err)
		}
	}

	if m.configPath != "" {
		_ = os.Remove(m.configPath)
		m.configPath = ""
	}
	m.mu.Unlock()
}

// parseClashApiPort extracts the port from experimental.clash_api.external_controller
// in the validated sing-box configuration. Returns DefaultClashApiPort if absent or invalid.
func parseClashApiPort(configJSON string) int {
	var parsed struct {
		Experimental struct {
			ClashAPI struct {
				ExternalController string `json:"external_controller"`
			} `json:"clash_api"`
		} `json:"experimental"`
	}
	if err := json.Unmarshal([]byte(configJSON), &parsed); err == nil {
		ec := parsed.Experimental.ClashAPI.ExternalController
		if _, portStr, err := net.SplitHostPort(ec); err == nil {
			if port, err := strconv.Atoi(portStr); err == nil && port >= 1024 && port <= 65535 {
				return port
			}
		}
	}
	return DefaultClashApiPort
}

func parseSystemProxyPort(configJSON string) int {
	var cfg struct {
		Inbounds []struct {
			Type       string `json:"type"`
			ListenPort int    `json:"listen_port"`
		} `json:"inbounds"`
	}
	if json.Unmarshal([]byte(configJSON), &cfg) == nil && len(cfg.Inbounds) == 1 && cfg.Inbounds[0].Type == "mixed" {
		return cfg.Inbounds[0].ListenPort
	}
	return 0
}

// pollRealTrafficStats streams real-time traffic statistics from sing-box clash_api.
// Upstream parity: when the config sets experimental.clash_api.secret, the
// /traffic endpoint requires `Authorization: Bearer <secret>`.
func (m *TunnelManager) pollRealTrafficStats(stopCh <-chan struct{}, clashSecret string, port int) {
	if port <= 0 {
		port = DefaultClashApiPort
	}
	trafficUrl := fmt.Sprintf("http://127.0.0.1:%d/traffic", port)
	client := &http.Client{Timeout: 0}

	for {
		select {
		case <-stopCh:
			return
		default:
		}

		req, err := http.NewRequestWithContext(context.Background(), "GET", trafficUrl, nil)
		if err != nil {
			time.Sleep(1 * time.Second)
			continue
		}
		if clashSecret != "" {
			req.Header.Set("Authorization", "Bearer "+clashSecret)
		}

		resp, err := client.Do(req)
		if err != nil {
			time.Sleep(1 * time.Second)
			continue
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			time.Sleep(time.Second)
			continue
		}

		reader := bufio.NewReader(resp.Body)
		for {
			select {
			case <-stopCh:
				resp.Body.Close()
				return
			default:
			}

			line, err := reader.ReadBytes('\n')
			if err != nil {
				resp.Body.Close()
				break
			}

			var stats struct {
				Up   int64 `json:"up"`
				Down int64 `json:"down"`
			}
			if err := json.Unmarshal(line, &stats); err == nil {
				m.mu.Lock()
				if m.stopStats == stopCh && m.status == StatusConnecting {
					m.status = StatusConnected
					m.activeSince = time.Now()
				}
				m.mu.Unlock()
				atomic.StoreInt64(&m.upBps, stats.Up)
				atomic.StoreInt64(&m.downBps, stats.Down)
				atomic.AddInt64(&m.totalUp, stats.Up)
				atomic.AddInt64(&m.totalDown, stats.Down)
			}
		}
	}
}

func (m *TunnelManager) Stop() error {
	m.lifecycleMu.Lock()
	defer m.lifecycleMu.Unlock()
	m.mu.Lock()

	if m.status == StatusDisconnected {
		m.mu.Unlock()
		return nil
	}

	log.Printf("[TUNNEL] Stopping VPN tunnel and releasing Wintun interface...")

	if m.stopStats != nil {
		close(m.stopStats)
		m.stopStats = nil
	}

	if m.cancelTunnel != nil {
		m.cancelTunnel()
	}

	if m.singboxCmd != nil && m.singboxCmd.Process != nil {
		_ = m.singboxCmd.Process.Kill()
	}
	m.singboxCmd = nil

	if m.configPath != "" {
		_ = os.Remove(m.configPath)
		m.configPath = ""
	}

	m.status = StatusDisconnected
	m.lastError = ""
	m.assignedIp = ""
	m.clashSecret = ""
	m.proxyPort = 0
	m.activeSince = time.Time{}
	atomic.StoreInt64(&m.downBps, 0)
	atomic.StoreInt64(&m.upBps, 0)

	monitorDone := m.monitorDone
	// Release the lock before waiting: the monitor goroutine needs it to
	// settle this generation's state.
	m.mu.Unlock()

	// Wait for this generation's monitor goroutine to finish before returning.
	// A Start() that follows Stop() then cannot
	// race a monitor goroutine that still holds a reference to the previous
	// tunnel.
	if monitorDone != nil {
		<-monitorDone
	}

	log.Printf("[TUNNEL] VPN Tunnel stopped successfully.")
	return nil
}

func (m *TunnelManager) GetStats() StatsResponse {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var uptime int64
	if m.status == StatusConnected && !m.activeSince.IsZero() {
		uptime = int64(time.Since(m.activeSince).Seconds())
	}

	_, wintunErr := os.Stat(m.wintunDllPath)

	return StatsResponse{
		Status:      m.status,
		LastError:   m.lastError,
		AssignedIp:  m.assignedIp,
		Country:     m.country,
		City:        m.city,
		UptimeSec:   uptime,
		DownlinkBps: atomic.LoadInt64(&m.downBps),
		UplinkBps:   atomic.LoadInt64(&m.upBps),
		TotalDown:   atomic.LoadInt64(&m.totalDown),
		TotalUp:     atomic.LoadInt64(&m.totalUp),
		Engine:      "sing-box official core",
		Wintun:      wintunErr == nil,
		ProxyPort:   m.proxyPort,
	}
}

// Windows Service Implementation
type vpnWindowsService struct{}

func (s *vpnWindowsService) Execute(args []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (ssec bool, errno uint32) {
	const cmdsAccepted = svc.AcceptStop | svc.AcceptShutdown
	changes <- svc.Status{State: svc.StartPending}

	server := startHttpServer()
	changes <- svc.Status{State: svc.Running, Accepts: cmdsAccepted}

	for req := range r {
		switch req.Cmd {
		case svc.Interrogate:
			changes <- req.CurrentStatus
		case svc.Stop, svc.Shutdown:
			changes <- svc.Status{State: svc.StopPending}
			if err := manager.Stop(); err != nil {
				log.Printf("[SERVICE] Tunnel cleanup failed during service shutdown: %v", err)
			}
			server.Shutdown(context.Background())
			return false, 0
		default:
			log.Printf("[SERVICE] Unexpected control request #%d", req.Cmd)
		}
	}
	return false, 0
}

func getOrInitIpcToken() string {
	if daemonAuthToken != "" {
		return daemonAuthToken
	}

	// Environment overrides are only for local development. A Windows service must
	// use the profile explicitly provisioned by the elevated installer.
	if !daemonRunningAsService {
		if envToken := strings.TrimSpace(os.Getenv(ipcTokenEnvVar)); envToken != "" {
			daemonAuthToken = envToken
			return daemonAuthToken
		}
	}

	localAppData := os.Getenv("LOCALAPPDATA")
	userSID, err := currentProcessSID()
	if err != nil {
		log.Printf("[IPC] Could not identify current user SID: %v", err)
		return ""
	}
	if daemonRunningAsService {
		configuredProfile, configuredSID, err := readIpcClientProfile()
		if err != nil {
			log.Printf("[IPC] No authorized client profile configured; privileged IPC is disabled: %v", err)
			return ""
		}
		localAppData = configuredProfile
		userSID = configuredSID
	}
	if strings.TrimSpace(localAppData) == "" {
		log.Printf("[IPC] LOCALAPPDATA is unavailable; privileged IPC is disabled")
		return ""
	}

	if existing := readIpcTokenFromDisk(localAppData); existing != "" {
		daemonAuthToken = existing
		return daemonAuthToken
	}
	if daemonRunningAsService {
		log.Printf("[IPC] Provisioned token is missing or invalid; privileged IPC is disabled")
		return ""
	}

	token, err := generateIpcToken()
	if err != nil {
		log.Printf("[IPC] Could not generate authentication token: %v", err)
		return ""
	}
	if err := writeIpcToken(localAppData, userSID, token); err != nil {
		log.Printf("[IPC] Could not persist authentication token: %v", err)
		return ""
	}
	daemonAuthToken = token
	return daemonAuthToken
}

// IPC token storage.
//
// Threat model: the daemon runs as SYSTEM and starts the core with a config supplied
// over IPC, so this bearer token is the only thing between a local unprivileged
// process and SYSTEM-level control of the VPN core. It must therefore be readable by
// exactly the installing user's profile. The service reads the authorized profile
// path from its HKLM service Parameters key; it never searches other profiles or
// migrates the old shared ProgramData token.
const (
	ipcTokenFileName = "ipc.token"
	ipcTokenEnvVar   = "AEROVPN_IPC_TOKEN"
	ipcTokenSubDir   = "AeroVPN"
	ipcProfileRegKey = `SYSTEM\CurrentControlSet\Services\AeroVpnDaemon\Parameters`
	ipcProfileRegVal = "IpcClientLocalAppData"
	ipcProfileSidVal = "IpcClientSid"
)

func ipcTokenPathFor(localAppData string) string {
	return filepath.Join(localAppData, ipcTokenSubDir, ipcTokenFileName)
}

var shGetKnownFolderPath = windows.NewLazySystemDLL("shell32.dll").NewProc("SHGetKnownFolderPath")

// interactiveClientProfile identifies the desktop user rather than the elevated
// Setup token, which can belong to a different administrator after an over-the-
// shoulder UAC prompt.
func interactiveClientProfile() (string, string, error) {
	shell := windows.GetShellWindow()
	if shell == 0 {
		return "", "", fmt.Errorf("could not identify the interactive Windows shell")
	}
	var pid uint32
	if _, err := windows.GetWindowThreadProcessId(shell, &pid); err != nil || pid == 0 {
		return "", "", fmt.Errorf("could not identify the interactive Windows user process: %v", err)
	}
	process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return "", "", fmt.Errorf("open interactive shell process: %w", err)
	}
	defer windows.CloseHandle(process)
	var verifiedPID uint32
	if windows.GetShellWindow() != shell {
		return "", "", fmt.Errorf("interactive shell changed while resolving its account")
	}
	windows.GetWindowThreadProcessId(shell, &verifiedPID)
	if verifiedPID != pid {
		return "", "", fmt.Errorf("interactive shell process changed while resolving its account")
	}
	var token windows.Token
	if err := windows.OpenProcessToken(process, windows.TOKEN_QUERY, &token); err != nil {
		return "", "", fmt.Errorf("open interactive shell token: %w", err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil || user == nil || user.User.Sid == nil {
		return "", "", fmt.Errorf("read interactive shell SID: %v", err)
	}
	localAppData, err := knownFolderForToken(token)
	if err != nil {
		return "", "", err
	}
	return localAppData, user.User.Sid.String(), nil
}

func knownFolderForToken(token windows.Token) (string, error) {
	var path *uint16
	result, _, _ := shGetKnownFolderPath.Call(
		uintptr(unsafe.Pointer(windows.FOLDERID_LocalAppData)), 0, uintptr(token), uintptr(unsafe.Pointer(&path)))
	if result != 0 {
		return "", fmt.Errorf("resolve interactive user's Local AppData: %w", syscall.Errno(result))
	}
	if path == nil {
		return "", fmt.Errorf("resolve interactive user's Local AppData: empty path")
	}
	defer windows.CoTaskMemFree(unsafe.Pointer(path))
	value := windows.UTF16PtrToString(path)
	if !filepath.IsAbs(value) {
		return "", fmt.Errorf("interactive user's Local AppData path is invalid")
	}
	return filepath.Clean(value), nil
}

func currentProcessSID() (string, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil || user == nil || user.User.Sid == nil {
		return "", fmt.Errorf("read current process SID: %v", err)
	}
	return user.User.Sid.String(), nil
}

func generateIpcToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func ntCreateIpcEntry(parent windows.Handle, name string, access, share, disposition, options uint32, sd *windows.SECURITY_DESCRIPTOR) (windows.Handle, error) {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `\/`) || strings.IndexByte(name, 0) >= 0 {
		return 0, fmt.Errorf("invalid IPC path component %q", name)
	}
	// NtCreateFile requires SYNCHRONIZE access if FILE_SYNCHRONOUS_IO_ALERT or
	// FILE_SYNCHRONOUS_IO_NONALERT is specified in options, returning
	// STATUS_INVALID_PARAMETER (0xC000000D) otherwise.
	if options&(windows.FILE_SYNCHRONOUS_IO_ALERT|windows.FILE_SYNCHRONOUS_IO_NONALERT) != 0 {
		access |= windows.SYNCHRONIZE
	}
	objectName, err := windows.NewNTUnicodeString(name)
	if err != nil {
		return 0, err
	}
	attributes := &windows.OBJECT_ATTRIBUTES{
		Length:             uint32(unsafe.Sizeof(windows.OBJECT_ATTRIBUTES{})),
		RootDirectory:      parent,
		ObjectName:         objectName,
		Attributes:         windows.OBJ_CASE_INSENSITIVE,
		SecurityDescriptor: sd,
	}
	var handle windows.Handle
	var status windows.IO_STATUS_BLOCK
	if err := windows.NtCreateFile(&handle, access, attributes, &status, nil,
		windows.FILE_ATTRIBUTE_NORMAL, share, disposition, options, 0, 0); err != nil {
		return 0, err
	}
	return handle, nil
}

func isMissingIpcPath(err error) bool {
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || errors.Is(err, windows.ERROR_PATH_NOT_FOUND) {
		return true
	}
	var status windows.NTStatus
	ok := errors.As(err, &status)
	return ok && (status == windows.STATUS_OBJECT_NAME_NOT_FOUND || status == windows.STATUS_OBJECT_PATH_NOT_FOUND)
}

func openIpcDirectoryAt(parent windows.Handle, name string, access uint32) (windows.Handle, error) {
	handle, err := ntCreateIpcEntry(parent, name, access|windows.SYNCHRONIZE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, windows.FILE_OPEN,
		windows.FILE_DIRECTORY_FILE|windows.FILE_OPEN_REPARSE_POINT|windows.FILE_SYNCHRONOUS_IO_NONALERT, nil)
	if err != nil {
		return 0, err
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		_ = windows.CloseHandle(handle)
		return 0, err
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
		_ = windows.CloseHandle(handle)
		return 0, fmt.Errorf("IPC path component %q is not a regular directory", name)
	}
	return handle, nil
}

// openIpcDirectory walks each component relative to the previously opened
// directory handle. No component is followed as a reparse point and every later
// lookup is anchored to an already verified directory object.
func openIpcDirectory(path string) (windows.Handle, error) {
	if strings.IndexByte(path, 0) >= 0 || !filepath.IsAbs(path) {
		return 0, fmt.Errorf("IPC token path must be an absolute local path")
	}
	path = filepath.Clean(path)
	volume := filepath.VolumeName(path)
	if volume == "" || strings.HasPrefix(volume, `\\`) {
		return 0, fmt.Errorf("IPC token path must be on a local volume")
	}
	rootPath := volume + `\`
	handle, err := windows.CreateFile(windows.StringToUTF16Ptr(rootPath),
		windows.FILE_READ_ATTRIBUTES|windows.SYNCHRONIZE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return 0, fmt.Errorf("open IPC volume root: %w", err)
	}
	var rootInfo windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &rootInfo); err != nil ||
		rootInfo.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 ||
		rootInfo.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
		_ = windows.CloseHandle(handle)
		if err != nil {
			return 0, fmt.Errorf("inspect IPC volume root: %w", err)
		}
		return 0, fmt.Errorf("IPC volume root is not a regular directory")
	}
	remainder := strings.TrimLeft(strings.TrimPrefix(path, volume), `\/`)
	parts := strings.FieldsFunc(remainder, func(r rune) bool { return r == '\\' || r == '/' })
	for _, part := range parts {
		child, openErr := openIpcDirectoryAt(handle, part, windows.FILE_READ_ATTRIBUTES)
		_ = windows.CloseHandle(handle)
		if openErr != nil {
			return 0, fmt.Errorf("open IPC path component %q: %w", part, openErr)
		}
		handle = child
	}
	return handle, nil
}

func createSecureIpcDirectory(parent windows.Handle, name, userSID string) (windows.Handle, error) {
	if _, err := windows.StringToSid(userSID); err != nil {
		return 0, fmt.Errorf("invalid IPC client SID: %w", err)
	}
	sddl := "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;GRGX;;;" + userSID + ")"
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return 0, fmt.Errorf("build IPC token directory ACL: %w", err)
	}
	access := uint32(windows.FILE_READ_ATTRIBUTES | windows.READ_CONTROL | windows.WRITE_DAC | windows.SYNCHRONIZE)
	share := uint32(windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE)
	// FILE_OPEN_REPARSE_POINT is only meaningful for FILE_OPEN (it refuses to
	// follow a symlink); combining it with FILE_CREATE fails outright with
	// STATUS_INVALID_PARAMETER on NTFS, so the create pass omits it.
	createOptions := uint32(windows.FILE_DIRECTORY_FILE | windows.FILE_SYNCHRONOUS_IO_NONALERT)
	openOptions := uint32(windows.FILE_DIRECTORY_FILE | windows.FILE_OPEN_REPARSE_POINT | windows.FILE_SYNCHRONOUS_IO_NONALERT)
	handle, err := ntCreateIpcEntry(parent, name, access, share, windows.FILE_CREATE, createOptions, sd)
	if status, ok := err.(windows.NTStatus); ok && status == windows.STATUS_OBJECT_NAME_COLLISION {
		// Create then open gives an unambiguous existing-object path and lets
		// the normal checks reject an existing reparse point.
		handle, err = ntCreateIpcEntry(parent, name, access, share, windows.FILE_OPEN, openOptions, nil)
	}
	if err != nil {
		return 0, fmt.Errorf("create or open IPC token directory: %w", err)
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		_ = windows.CloseHandle(handle)
		return 0, fmt.Errorf("inspect IPC token directory: %w", err)
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
		_ = windows.CloseHandle(handle)
		return 0, fmt.Errorf("IPC token path component is not a regular directory")
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		_ = windows.CloseHandle(handle)
		return 0, fmt.Errorf("read IPC token directory ACL: %w", err)
	}
	if err := windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, dacl, nil); err != nil {
		_ = windows.CloseHandle(handle)
		return 0, fmt.Errorf("apply IPC token directory ACL: %w", err)
	}
	// The caller keeps this handle and creates the token relative to it.
	return handle, nil
}

func openIpcFileAt(parent windows.Handle, name string, access uint32) (windows.Handle, error) {
	handle, err := ntCreateIpcEntry(parent, name, access|windows.SYNCHRONIZE,
		windows.FILE_SHARE_READ, windows.FILE_OPEN,
		windows.FILE_NON_DIRECTORY_FILE|windows.FILE_OPEN_REPARSE_POINT|windows.FILE_SYNCHRONOUS_IO_NONALERT, nil)
	if err != nil {
		return 0, err
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		_ = windows.CloseHandle(handle)
		return 0, err
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0 {
		_ = windows.CloseHandle(handle)
		return 0, fmt.Errorf("IPC token is not a regular file")
	}
	return handle, nil
}

func markIpcFileForDeletion(handle windows.Handle) error {
	deleteFile := byte(1)
	var status windows.IO_STATUS_BLOCK
	return windows.NtSetInformationFile(handle, &status, (*byte)(unsafe.Pointer(&deleteFile)),
		uint32(unsafe.Sizeof(deleteFile)), windows.FileDispositionInformation)
}

func deleteIpcFileAt(parent windows.Handle, name string) error {
	handle, err := openIpcFileAt(parent, name, windows.DELETE|windows.FILE_READ_ATTRIBUTES)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(handle)
	return markIpcFileForDeletion(handle)
}

func readIpcTokenFromDisk(localAppData string) string {
	if strings.IndexByte(localAppData, 0) >= 0 {
		return ""
	}
	path := ipcTokenPathFor(localAppData)
	localDataHandle, err := openIpcDirectory(localAppData)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(localDataHandle)
	tokenDirectoryHandle, err := openIpcDirectoryAt(localDataHandle, ipcTokenSubDir, windows.FILE_READ_ATTRIBUTES)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(tokenDirectoryHandle)
	handle, err := openIpcFileAt(tokenDirectoryHandle, ipcTokenFileName, windows.GENERIC_READ)
	if err != nil {
		return ""
	}
	file := os.NewFile(uintptr(handle), path)
	if file == nil {
		_ = windows.CloseHandle(handle)
		return ""
	}
	defer file.Close()
	var info windows.ByHandleFileInformation
	if windows.GetFileInformationByHandle(handle, &info) != nil ||
		info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 ||
		info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0 {
		return ""
	}
	data, err := io.ReadAll(io.LimitReader(file, 4096))
	if err != nil {
		return ""
	}
	token := strings.TrimSpace(string(data))
	if len(token) != 64 {
		return ""
	}
	if decoded, err := hex.DecodeString(token); err != nil || len(decoded) != 32 {
		return ""
	}
	return token
}

func writeIpcToken(localAppData, userSID, token string) error {
	if !filepath.IsAbs(localAppData) || strings.IndexByte(localAppData, 0) >= 0 {
		return fmt.Errorf("client LOCALAPPDATA path must be absolute")
	}
	if _, err := windows.StringToSid(userSID); err != nil {
		return fmt.Errorf("invalid IPC client SID: %w", err)
	}
	if decoded, err := hex.DecodeString(token); err != nil || len(decoded) != 32 {
		return fmt.Errorf("IPC token must be a 32-byte hexadecimal value")
	}
	localDataHandle, err := openIpcDirectory(localAppData)
	if err != nil {
		return fmt.Errorf("open client LOCALAPPDATA directory: %w", err)
	}
	defer windows.CloseHandle(localDataHandle)
	directoryHandle, err := createSecureIpcDirectory(localDataHandle, ipcTokenSubDir, userSID)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(directoryHandle)
	if err := deleteIpcFileAt(directoryHandle, ipcTokenFileName); err != nil && !isMissingIpcPath(err) {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;" + userSID + ")")
	if err != nil {
		return fmt.Errorf("build IPC token file ACL: %w", err)
	}
	handle, err := ntCreateIpcEntry(directoryHandle, ipcTokenFileName, windows.GENERIC_WRITE|windows.FILE_READ_ATTRIBUTES|windows.DELETE|windows.SYNCHRONIZE,
		windows.FILE_SHARE_READ, windows.FILE_CREATE,
		windows.FILE_NON_DIRECTORY_FILE|windows.FILE_SYNCHRONOUS_IO_NONALERT|windows.FILE_WRITE_THROUGH, sd)
	if err != nil {
		return fmt.Errorf("create IPC token file: %w", err)
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil || info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		_ = markIpcFileForDeletion(handle)
		_ = windows.CloseHandle(handle)
		if err != nil {
			return fmt.Errorf("verify IPC token file: %w", err)
		}
		return fmt.Errorf("refusing IPC token reparse point")
	}
	data := []byte(token)
	var written uint32
	if err := windows.WriteFile(handle, data, &written, nil); err != nil {
		_ = markIpcFileForDeletion(handle)
		_ = windows.CloseHandle(handle)
		return fmt.Errorf("write IPC token file: %w", err)
	}
	if int(written) != len(data) {
		_ = markIpcFileForDeletion(handle)
		_ = windows.CloseHandle(handle)
		return fmt.Errorf("write IPC token file: incomplete write")
	}
	if err := windows.FlushFileBuffers(handle); err != nil {
		_ = markIpcFileForDeletion(handle)
		_ = windows.CloseHandle(handle)
		return fmt.Errorf("flush IPC token file: %w", err)
	}
	if err := windows.CloseHandle(handle); err != nil {
		return fmt.Errorf("close IPC token file: %w", err)
	}
	return nil
}

func readIpcClientProfile() (string, string, error) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, ipcProfileRegKey, registry.QUERY_VALUE)
	if err != nil {
		return "", "", err
	}
	defer key.Close()
	profile, _, err := key.GetStringValue(ipcProfileRegVal)
	if err != nil {
		return "", "", err
	}
	userSID, _, err := key.GetStringValue(ipcProfileSidVal)
	if err != nil {
		return "", "", err
	}
	profile = strings.TrimSpace(profile)
	if profile == "" || !filepath.IsAbs(profile) || strings.IndexByte(profile, 0) >= 0 {
		return "", "", fmt.Errorf("authorized client LOCALAPPDATA path is invalid")
	}
	if _, err := windows.StringToSid(userSID); err != nil {
		return "", "", fmt.Errorf("authorized client SID is invalid: %w", err)
	}
	return filepath.Clean(profile), userSID, nil
}

func writeIpcClientProfile(profile, userSID string) error {
	if strings.TrimSpace(profile) == "" || !filepath.IsAbs(profile) || strings.IndexByte(profile, 0) >= 0 {
		return fmt.Errorf("client LOCALAPPDATA path must be an absolute path")
	}
	if _, err := windows.StringToSid(userSID); err != nil {
		return fmt.Errorf("client SID is invalid: %w", err)
	}
	key, _, err := registry.CreateKey(registry.LOCAL_MACHINE, ipcProfileRegKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	if err := key.SetStringValue(ipcProfileSidVal, userSID); err != nil {
		return err
	}
	return key.SetStringValue(ipcProfileRegVal, filepath.Clean(profile))
}

func clearIpcClientProfile() {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, ipcProfileRegKey, registry.SET_VALUE)
	if err != nil {
		return
	}
	defer key.Close()
	_ = key.DeleteValue(ipcProfileRegVal)
	_ = key.DeleteValue(ipcProfileSidVal)
}

func provisionIpcToken(profile, userSID string) error {
	token, err := generateIpcToken()
	if err != nil {
		return fmt.Errorf("generate IPC token: %w", err)
	}
	if err := writeIpcToken(profile, userSID, token); err != nil {
		return fmt.Errorf("write IPC token: %w", err)
	}
	if err := writeIpcClientProfile(profile, userSID); err != nil {
		removeIpcToken(profile)
		return fmt.Errorf("register authorized IPC profile: %w", err)
	}
	removeLegacyProgramDataToken()
	return nil
}

func removeLegacyProgramDataToken() {
	programData := strings.TrimSpace(os.Getenv("ProgramData"))
	if programData == "" {
		return
	}
	programDataHandle, err := openIpcDirectory(programData)
	if err != nil {
		if !isMissingIpcPath(err) {
			log.Printf("[IPC] Could not open ProgramData while removing legacy token: %v", err)
		}
		return
	}
	defer windows.CloseHandle(programDataHandle)
	tokenDirectoryHandle, err := openIpcDirectoryAt(programDataHandle, "AeroVPN", windows.FILE_READ_ATTRIBUTES)
	if err != nil {
		if !isMissingIpcPath(err) {
			log.Printf("[IPC] Could not open legacy token directory: %v", err)
		}
		return
	}
	defer windows.CloseHandle(tokenDirectoryHandle)
	if err := deleteIpcFileAt(tokenDirectoryHandle, ipcTokenFileName); err != nil && !isMissingIpcPath(err) {
		log.Printf("[IPC] Could not remove legacy shared token under %s: %v", programData, err)
	}
}

func isOriginAllowed(origin string) bool {
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return false
	}
	hostname := strings.ToLower(u.Hostname())
	return hostname == "127.0.0.1" || hostname == "localhost" || hostname == "::1"
}

func isHostAllowed(host string) bool {
	if host == "" {
		return true
	}
	h := strings.ToLower(strings.TrimSpace(host))
	hostname, port, err := net.SplitHostPort(h)
	if err != nil {
		hostname = strings.Trim(h, "[]")
	} else {
		hostname = strings.Trim(hostname, "[]")
		if port != "" {
			p, err := strconv.Atoi(port)
			if err != nil || p < 1 || p > 65535 {
				return false
			}
		}
	}
	return hostname == "127.0.0.1" || hostname == "localhost" || hostname == "::1"
}

func verifyIpcAuth(r *http.Request) bool {
	expected := getOrInitIpcToken()
	// Fail closed: an empty expectation must never mean "no auth required"
	// (that would expose SYSTEM-level tunnel control to every local process).
	if expected == "" {
		return false
	}

	provided := strings.TrimSpace(r.Header.Get("X-AeroVPN-Token"))
	if provided == "" {
		authHeader := strings.TrimSpace(r.Header.Get("Authorization"))
		if strings.HasPrefix(strings.ToLower(authHeader), "bearer ") {
			provided = strings.TrimSpace(authHeader[7:])
		}
	}

	return subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1
}

func startHttpServer() *http.Server {
	token := getOrInitIpcToken()
	log.Printf("[IPC] Initialized IPC authentication token (length: %d)", len(token))

	mux := http.NewServeMux()

	// Public health probe (loopback only). It answers unauthenticated requests
	// from any local process, so it must stay minimal: no installation paths,
	// no core layout and no version details.
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"status": "ok",
		})
	})

	// Privileged: Start Tunnel
	mux.HandleFunc("/tunnel/start", func(w http.ResponseWriter, r *http.Request) {
		if !verifyIpcAuth(r) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(map[string]string{"error": "Unauthorized: Invalid or missing IPC authentication token"})
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var req StartRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Bad request", http.StatusBadRequest)
			return
		}
		if err := manager.Start(req); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(manager.GetStats())
	})

	// Privileged: Stop Tunnel
	mux.HandleFunc("/tunnel/stop", func(w http.ResponseWriter, r *http.Request) {
		if !verifyIpcAuth(r) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(map[string]string{"error": "Unauthorized: Invalid or missing IPC authentication token"})
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if err := manager.Stop(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(manager.GetStats())
	})

	// Telemetry stats (authenticated: exposes session metadata).
	mux.HandleFunc("/tunnel/stats", func(w http.ResponseWriter, r *http.Request) {
		if !verifyIpcAuth(r) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(map[string]string{"error": "Unauthorized: Invalid or missing IPC authentication token"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(manager.GetStats())
	})

	// Security middleware: Host verification (DNS rebinding) and Origin restriction (CSRF protection)
	securityHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 1. DNS Rebinding Defense: Host must be localhost / 127.0.0.1
		if !isHostAllowed(r.Host) {
			http.Error(w, "Forbidden: Untrusted Host header", http.StatusForbidden)
			return
		}

		// 2. Cross-Origin CSRF Defense: Block foreign Origin headers
		origin := r.Header.Get("Origin")
		if origin != "" {
			if !isOriginAllowed(origin) {
				http.Error(w, "Forbidden: Cross-origin access prohibited", http.StatusForbidden)
				return
			}
			// Only allow verified localhost origins (never wildcard *)
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-AeroVPN-Token, X-AeroVPN-Client")
		}

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		mux.ServeHTTP(w, r)
	})

	server := &http.Server{
		Addr:    "127.0.0.1:9527",
		Handler: securityHandler,
	}

	go func() {
		log.Printf("[IPC] Privileged IPC Server listening on http://127.0.0.1:9527")
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server listen failed: %v", err)
		}
	}()

	return server
}

// Service command-line management
func handleServiceCommand(cmd, clientLocalAppData string) error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("could not connect to Windows Service Manager: %v", err)
	}
	defer m.Disconnect()

	exePath, err := os.Executable()
	if err != nil {
		return err
	}

	switch cmd {
	case "install":
		interactiveProfile, interactiveSID, profileErr := interactiveClientProfile()
		if profileErr != nil {
			return fmt.Errorf("identify the client account for service authorization: %w", profileErr)
		}
		if strings.TrimSpace(clientLocalAppData) != "" && !strings.EqualFold(filepath.Clean(clientLocalAppData), interactiveProfile) {
			return fmt.Errorf("requested client profile does not match the interactive desktop user")
		}
		clientLocalAppData = interactiveProfile

		s, err := m.OpenService(ServiceName)
		if err == nil {
			defer s.Close()
			log.Printf("Service %s is already installed. Updating configuration...", ServiceName)
			if err := stopServiceAndWait(s); err != nil {
				return fmt.Errorf("could not stop existing service before credential rotation: %w", err)
			}
			cfg, err := s.Config()
			if err != nil {
				return fmt.Errorf("could not read existing service configuration: %w", err)
			}
			cfg.DisplayName = ServiceDisplayName
			cfg.Description = ServiceDescription
			cfg.BinaryPathName = exePath
			cfg.StartType = mgr.StartAutomatic
			if err := s.UpdateConfig(cfg); err != nil {
				return fmt.Errorf("could not update service configuration: %w", err)
			}
			if err := provisionIpcToken(clientLocalAppData, interactiveSID); err != nil {
				return err
			}
			if err := grantClientServiceStartAccess(s, interactiveSID); err != nil {
				return err
			}
			return nil
		}
		s, err = m.CreateService(ServiceName, exePath, mgr.Config{
			DisplayName: ServiceDisplayName,
			Description: ServiceDescription,
			StartType:   mgr.StartAutomatic,
		})
		if err != nil {
			return fmt.Errorf("failed to create service: %v", err)
		}
		defer s.Close()
		if err := provisionIpcToken(clientLocalAppData, interactiveSID); err != nil {
			_ = s.Delete()
			return err
		}
		if err := grantClientServiceStartAccess(s, interactiveSID); err != nil {
			_ = s.Delete()
			return err
		}
		log.Printf("Service %s successfully installed.", ServiceName)
		return nil

	case "uninstall":
		registeredProfile, _, profileErr := readIpcClientProfile()
		s, err := m.OpenService(ServiceName)
		if err != nil {
			log.Printf("Service %s already uninstalled or not found.", ServiceName)
			if err := cleanupLegacyFirewall(); err != nil {
				return fmt.Errorf("could not restore Windows Firewall policy: %w", err)
			}
			if profileErr == nil {
				removeIpcToken(registeredProfile)
			}
			clearIpcClientProfile()
			removeLegacyProgramDataToken()
			return nil
		}
		defer s.Close()
		if err := stopServiceAndWait(s); err != nil {
			return fmt.Errorf("could not stop service before removing its IPC credentials: %w", err)
		}
		if err := cleanupLegacyFirewall(); err != nil {
			return fmt.Errorf("could not restore Windows Firewall policy: %w", err)
		}
		if err := s.Delete(); err != nil {
			return fmt.Errorf("failed to delete service: %v", err)
		}
		if profileErr == nil {
			removeIpcToken(registeredProfile)
		}
		clearIpcClientProfile()
		removeLegacyProgramDataToken()
		log.Printf("Service %s successfully uninstalled.", ServiceName)
		return nil

	case "start":
		s, err := m.OpenService(ServiceName)
		if err != nil {
			return fmt.Errorf("service %s not found: %v", ServiceName, err)
		}
		defer s.Close()
		status, err := s.Query()
		if err != nil {
			return fmt.Errorf("could not query service state: %w", err)
		}
		if status.State == svc.Running {
			log.Printf("Service %s is already running.", ServiceName)
			return nil
		}
		if status.State == svc.StopPending {
			status, err = waitForServiceState(s, svc.Stopped, 30*time.Second)
			if err != nil {
				return err
			}
		}
		if status.State != svc.StartPending {
			if err := s.Start(); err != nil {
				status, queryErr := s.Query()
				if queryErr != nil || (status.State != svc.Running && status.State != svc.StartPending) {
					return fmt.Errorf("failed to start service: %w", err)
				}
			}
		}
		if _, err := waitForServiceState(s, svc.Running, 30*time.Second); err != nil {
			return err
		}
		log.Printf("Service %s started.", ServiceName)
		return nil

	case "stop":
		s, err := m.OpenService(ServiceName)
		if err != nil {
			log.Printf("Service %s not found or already stopped.", ServiceName)
			return nil
		}
		defer s.Close()
		status, err := s.Query()
		if err == nil && status.State == svc.Stopped {
			log.Printf("Service %s is already stopped.", ServiceName)
			return nil
		}
		status, err = s.Control(svc.Stop)
		if err != nil {
			log.Printf("Service %s stop notification: %v", ServiceName, err)
			return nil
		}
		// Wait for service to transition to stopped
		for i := 0; i < 25; i++ {
			time.Sleep(200 * time.Millisecond)
			status, err = s.Query()
			if err == nil && status.State == svc.Stopped {
				break
			}
		}
		log.Printf("Service %s stopped. State: %v", ServiceName, status.State)
		return nil
	}

	return fmt.Errorf("unknown service command: %s", cmd)
}

// grantClientServiceStartAccess allows only the interactive desktop user to
// query and start this service. The app can recover the SYSTEM service on its
// first launch without running its own process elevated.
func grantClientServiceStartAccess(service *mgr.Service, userSID string) error {
	if _, err := windows.StringToSid(userSID); err != nil {
		return fmt.Errorf("invalid client SID for service access: %w", err)
	}
	sddl := fmt.Sprintf("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;LCRP;;;%s)", userSID)
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return fmt.Errorf("build service access descriptor: %w", err)
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return fmt.Errorf("read service access descriptor: %w", err)
	}
	if err := windows.SetSecurityInfo(service.Handle, windows.SE_SERVICE,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, dacl, nil); err != nil {
		return fmt.Errorf("grant the desktop user permission to start the VPN service: %w", err)
	}
	return nil
}

func waitForServiceState(service *mgr.Service, target svc.State, timeout time.Duration) (svc.Status, error) {
	deadline := time.Now().Add(timeout)
	for {
		status, err := service.Query()
		if err != nil {
			return svc.Status{}, fmt.Errorf("could not query service state: %w", err)
		}
		if status.State == target {
			return status, nil
		}
		if target == svc.Running && status.State == svc.Stopped {
			return status, fmt.Errorf("service stopped before reaching Running (Win32 exit code %d, service exit code %d)", status.Win32ExitCode, status.ServiceSpecificExitCode)
		}
		if !time.Now().Before(deadline) {
			return status, fmt.Errorf("service did not reach state %v within %s (current state %v)", target, timeout, status.State)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func removeIpcToken(localAppData string) {
	if strings.TrimSpace(localAppData) == "" || !filepath.IsAbs(localAppData) || strings.IndexByte(localAppData, 0) >= 0 {
		return
	}
	path := ipcTokenPathFor(localAppData)
	localDataHandle, err := openIpcDirectory(localAppData)
	if err != nil {
		if !isMissingIpcPath(err) {
			log.Printf("[IPC] Could not open token profile directory: %v", err)
		}
		return
	}
	defer windows.CloseHandle(localDataHandle)
	tokenDirectoryHandle, err := openIpcDirectoryAt(localDataHandle, ipcTokenSubDir, windows.FILE_READ_ATTRIBUTES)
	if err != nil {
		if !isMissingIpcPath(err) {
			log.Printf("[IPC] Could not open token directory: %v", err)
		}
		return
	}
	defer windows.CloseHandle(tokenDirectoryHandle)
	if err := deleteIpcFileAt(tokenDirectoryHandle, ipcTokenFileName); err != nil && !isMissingIpcPath(err) {
		log.Printf("[IPC] Could not remove IPC token at %s: %v", path, err)
	}
}

func stopServiceAndWait(s *mgr.Service) error {
	status, err := s.Query()
	if err != nil {
		return err
	}
	if status.State == svc.Stopped {
		return nil
	}
	if status.State != svc.StopPending {
		if _, err := s.Control(svc.Stop); err != nil {
			return err
		}
	}
	for i := 0; i < 50; i++ {
		time.Sleep(100 * time.Millisecond)
		status, err = s.Query()
		if err == nil && status.State == svc.Stopped {
			return nil
		}
	}
	return fmt.Errorf("service did not stop within 5 seconds")
}

func parseServiceCommand(args []string) (string, error) {
	if len(args) < 2 {
		return "", nil
	}

	arg1 := strings.ToLower(strings.TrimLeft(args[1], "-/"))

	if arg1 == "service" {
		if len(args) < 3 {
			return "", fmt.Errorf("missing service subcommand. Usage: vpn-daemon.exe service [install|uninstall|start|stop]")
		}
		sub := strings.ToLower(strings.TrimLeft(args[2], "-/"))
		if sub == "install" || sub == "uninstall" || sub == "start" || sub == "stop" {
			return sub, nil
		}
		return "", fmt.Errorf("unknown service subcommand '%s'. Valid: install, uninstall, start, stop", args[2])
	}

	if arg1 == "install" || arg1 == "uninstall" || arg1 == "start" || arg1 == "stop" {
		return arg1, nil
	}

	if arg1 == "version" || arg1 == "v" {
		return "version", nil
	}

	if arg1 == "help" || arg1 == "h" || arg1 == "?" {
		return "help", nil
	}

	return "", fmt.Errorf("unrecognized command '%s'. Usage: vpn-daemon.exe [service] [install|uninstall|start|stop]", args[1])
}

func parseIpcClientLocalAppData(args []string) (string, error) {
	const option = "--client-local-app-data"
	for i := 1; i < len(args); i++ {
		arg := args[i]
		if strings.EqualFold(arg, option) {
			if i+1 >= len(args) || strings.TrimSpace(args[i+1]) == "" {
				return "", fmt.Errorf("%s requires a path", option)
			}
			return strings.Trim(strings.TrimSpace(args[i+1]), `"`), nil
		}
		if len(arg) > len(option) && strings.EqualFold(arg[:len(option)], option) && arg[len(option)] == '=' {
			profile := strings.Trim(strings.TrimSpace(arg[len(option)+1:]), `"`)
			if profile == "" {
				return "", fmt.Errorf("%s requires a path", option)
			}
			return profile, nil
		}
	}
	return "", nil
}

func main() {
	cmd, err := parseServiceCommand(os.Args)
	if err != nil {
		log.Fatalf("Command error: %v", err)
	}
	clientLocalAppData, err := parseIpcClientLocalAppData(os.Args)
	if err != nil {
		log.Fatalf("Command error: %v", err)
	}
	switch cmd {
	case "version":
		fmt.Printf("AeroVPN Daemon v%s\n", Version)
		return
	case "help":
		fmt.Printf("AeroVPN Privileged Helper Daemon v%s\n", Version)
		fmt.Printf("Usage: vpn-daemon.exe [service] [install|uninstall|start|stop]\n")
		return
	case "install", "uninstall", "start", "stop":
		if err := handleServiceCommand(cmd, clientLocalAppData); err != nil {
			log.Fatalf("Service command '%s' failed: %v", cmd, err)
		}
		return
	case "":
		// Continue to Windows Service check or Standalone mode
	default:
		log.Fatalf("Unhandled command: %s", cmd)
	}

	manager = NewTunnelManager()

	isService, err := svc.IsWindowsService()
	if err != nil {
		log.Fatalf("Failed to detect service environment: %v", err)
	}
	daemonRunningAsService = isService

	if isService {
		err = svc.Run(ServiceName, &vpnWindowsService{})
		if err != nil {
			log.Fatalf("Service execution failed: %v", err)
		}
		return
	}

	log.Printf("==================================================================")
	log.Printf(" AeroVPN Privileged Helper Daemon v%s (Standalone Mode)", Version)
	log.Printf("==================================================================")
	server := startHttpServer()

	stopSignal := make(chan os.Signal, 1)
	signal.Notify(stopSignal, os.Interrupt)
	<-stopSignal

	log.Printf("Shutting down AeroVPN Daemon...")
	if err := manager.Stop(); err != nil {
		log.Printf("[DAEMON] Tunnel cleanup failed during shutdown: %v", err)
	}
	server.Shutdown(context.Background())
}
