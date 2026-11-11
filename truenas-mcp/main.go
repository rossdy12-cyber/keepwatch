// truenas-mcp — a local MCP server (stdio) that gives Claude Code a shell on your TrueNAS over SSH.
// It makes an OUTBOUND SSH connection to the NAS (over Tailscale/LAN) — nothing listens inbound.
//
// Configure with env vars:
//   TRUENAS_HOST   (required)  Tailscale hostname or IP, e.g. nas-server or 100.x.y.z
//   TRUENAS_USER   (required)  e.g. truenas_admin or root
//   TRUENAS_PORT   (optional)  default 22
//   TRUENAS_SSH_KEY  (path to a private key)   -- preferred
//   TRUENAS_PASSWORD (password)                -- alternative to a key
//   TRUENAS_KNOWN_HOSTS (optional)  known_hosts path; default ~/.config/truenas-mcp/known_hosts
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

const serverName = "truenas-mcp"
const serverVersion = "1.0.0"
const maxOutput = 200 * 1024 // cap tool output at 200 KB

// ------------------------------------------------------------------ config

var (
	host     = strings.TrimSpace(os.Getenv("TRUENAS_HOST"))
	port     = envDefault("TRUENAS_PORT", "22")
	user     = strings.TrimSpace(os.Getenv("TRUENAS_USER"))
	keyPath  = strings.TrimSpace(os.Getenv("TRUENAS_SSH_KEY"))
	password = os.Getenv("TRUENAS_PASSWORD")
)

func envDefault(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func knownHostsPath() string {
	if p := strings.TrimSpace(os.Getenv("TRUENAS_KNOWN_HOSTS")); p != "" {
		return p
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		dir, _ = os.UserHomeDir()
	}
	d := filepath.Join(dir, "truenas-mcp")
	_ = os.MkdirAll(d, 0o700)
	return filepath.Join(d, "known_hosts")
}

// ------------------------------------------------------------------ SSH (lazy, cached)

var (
	sshMu     sync.Mutex
	sshClient *ssh.Client
)

func client() (*ssh.Client, error) {
	sshMu.Lock()
	defer sshMu.Unlock()
	if sshClient != nil {
		// quick liveness check
		if _, _, err := sshClient.SendRequest("keepalive@openssh.com", true, nil); err == nil {
			return sshClient, nil
		}
		sshClient.Close()
		sshClient = nil
	}
	if host == "" || user == "" {
		return nil, errors.New("TRUENAS_HOST and TRUENAS_USER must be set")
	}
	cfg := &ssh.ClientConfig{
		User:            user,
		HostKeyCallback: tofuHostKey(knownHostsPath()),
		Timeout:         12 * time.Second,
	}
	if keyPath != "" {
		keyBytes, err := os.ReadFile(keyPath)
		if err != nil {
			return nil, fmt.Errorf("reading TRUENAS_SSH_KEY: %w", err)
		}
		signer, err := ssh.ParsePrivateKey(keyBytes)
		if err != nil {
			return nil, fmt.Errorf("parsing SSH key: %w", err)
		}
		cfg.Auth = []ssh.AuthMethod{ssh.PublicKeys(signer)}
	} else if password != "" {
		cfg.Auth = []ssh.AuthMethod{ssh.Password(password)}
	} else {
		return nil, errors.New("set TRUENAS_SSH_KEY or TRUENAS_PASSWORD")
	}
	c, err := ssh.Dial("tcp", host+":"+port, cfg)
	if err != nil {
		return nil, err
	}
	sshClient = c
	return c, nil
}

// tofuHostKey trusts the host key on first use (pins it), then verifies it thereafter.
func tofuHostKey(path string) ssh.HostKeyCallback {
	return func(hostname string, remote net.Addr, key ssh.PublicKey) error {
		if _, err := os.Stat(path); err == nil {
			cb, err := knownhosts.New(path)
			if err == nil {
				e := cb(hostname, remote, key)
				if e == nil {
					return nil
				}
				var keyErr *knownhosts.KeyError
				if errors.As(e, &keyErr) && len(keyErr.Want) > 0 {
					return fmt.Errorf("host key mismatch for %s (possible MITM) — remove it from %s if you trust the change", hostname, path)
				}
				// unknown host: fall through and pin it
			}
		}
		line := knownhosts.Line([]string{knownhosts.Normalize(hostname), knownhosts.Normalize(remote.String())}, key)
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err == nil {
			_, _ = f.WriteString(line + "\n")
			f.Close()
		}
		return nil
	}
}

// ------------------------------------------------------------------ tools

func toolRun(args map[string]any) (string, bool) {
	command, _ := args["command"].(string)
	if strings.TrimSpace(command) == "" {
		return "command is required", true
	}
	timeout := 120 * time.Second
	if t, ok := args["timeout_seconds"].(float64); ok && t > 0 {
		timeout = time.Duration(t) * time.Second
	}
	c, err := client()
	if err != nil {
		return "SSH connect failed: " + err.Error(), true
	}
	session, err := c.NewSession()
	if err != nil {
		return "SSH session failed: " + err.Error(), true
	}
	defer session.Close()
	var out, errb bytes.Buffer
	session.Stdout = &out
	session.Stderr = &errb
	done := make(chan error, 1)
	go func() { done <- session.Run(command) }()
	exitCode := 0
	timedOut := false
	select {
	case e := <-done:
		if e != nil {
			var exitErr *ssh.ExitError
			if errors.As(e, &exitErr) {
				exitCode = exitErr.ExitStatus()
			} else {
				exitCode = -1
			}
		}
	case <-time.After(timeout):
		timedOut = true
		_ = session.Signal(ssh.SIGKILL)
		session.Close()
		exitCode = -1
	}
	result := map[string]any{
		"exit_code": exitCode,
		"stdout":    capStr(out.String()),
		"stderr":    capStr(errb.String()),
	}
	if timedOut {
		result["timed_out"] = true
	}
	b, _ := json.MarshalIndent(result, "", "  ")
	return string(b), exitCode != 0
}

func toolPutFile(args map[string]any) (string, bool) {
	remote, _ := args["remote_path"].(string)
	if strings.TrimSpace(remote) == "" {
		return "remote_path is required", true
	}
	var data []byte
	if content, ok := args["content"].(string); ok && content != "" {
		data = []byte(content)
	} else if lp, ok := args["local_path"].(string); ok && lp != "" {
		b, err := os.ReadFile(lp)
		if err != nil {
			return "reading local_path: " + err.Error(), true
		}
		data = b
	} else {
		return "provide content or local_path", true
	}
	c, err := client()
	if err != nil {
		return "SSH connect failed: " + err.Error(), true
	}
	sc, err := sftp.NewClient(c)
	if err != nil {
		return "SFTP failed: " + err.Error(), true
	}
	defer sc.Close()
	f, err := sc.Create(remote)
	if err != nil {
		return "create remote: " + err.Error(), true
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return "write remote: " + err.Error(), true
	}
	f.Close()
	if mode, ok := args["mode"].(string); ok && mode != "" {
		_ = sc.Chmod(remote, parseMode(mode))
	}
	return fmt.Sprintf("Wrote %d bytes to %s", len(data), remote), false
}

func toolGetFile(args map[string]any) (string, bool) {
	remote, _ := args["remote_path"].(string)
	if strings.TrimSpace(remote) == "" {
		return "remote_path is required", true
	}
	limit := maxOutput
	if m, ok := args["max_bytes"].(float64); ok && int(m) > 0 && int(m) < maxOutput {
		limit = int(m)
	}
	c, err := client()
	if err != nil {
		return "SSH connect failed: " + err.Error(), true
	}
	sc, err := sftp.NewClient(c)
	if err != nil {
		return "SFTP failed: " + err.Error(), true
	}
	defer sc.Close()
	f, err := sc.Open(remote)
	if err != nil {
		return "open remote: " + err.Error(), true
	}
	defer f.Close()
	buf := make([]byte, limit)
	n, _ := f.Read(buf)
	return string(buf[:n]), false
}

func capStr(s string) string {
	if len(s) > maxOutput {
		return s[:maxOutput] + "\n…[truncated]"
	}
	return s
}

func parseMode(s string) os.FileMode {
	var m uint32
	fmt.Sscanf(s, "%o", &m)
	if m == 0 {
		m = 0o644
	}
	return os.FileMode(m)
}

// ------------------------------------------------------------------ MCP stdio (JSON-RPC 2.0, newline-delimited)

type rpcReq struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

var stdout = bufio.NewWriter(os.Stdout)

func send(v any) {
	b, _ := json.Marshal(v)
	stdout.Write(b)
	stdout.WriteByte('\n')
	stdout.Flush()
}

func result(id json.RawMessage, res any) {
	send(map[string]any{"jsonrpc": "2.0", "id": rawOrNull(id), "result": res})
}
func rpcError(id json.RawMessage, code int, msg string) {
	send(map[string]any{"jsonrpc": "2.0", "id": rawOrNull(id), "error": map[string]any{"code": code, "message": msg}})
}
func rawOrNull(id json.RawMessage) any {
	if len(id) == 0 {
		return nil
	}
	return id
}

func textResult(id json.RawMessage, text string, isError bool) {
	result(id, map[string]any{
		"content": []map[string]any{{"type": "text", "text": text}},
		"isError": isError,
	})
}

func toolsSchema() []map[string]any {
	return []map[string]any{
		{
			"name":        "run",
			"description": "Run a shell command on the TrueNAS over SSH. Returns JSON {exit_code, stdout, stderr}. Full shell.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"command":         map[string]any{"type": "string", "description": "The shell command to run on the NAS."},
					"timeout_seconds": map[string]any{"type": "number", "description": "Max seconds before the command is killed (default 120)."},
				},
				"required": []string{"command"},
			},
		},
		{
			"name":        "put_file",
			"description": "Upload a file to the TrueNAS via SFTP. Provide either 'content' (text) or 'local_path'.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"remote_path": map[string]any{"type": "string", "description": "Destination path on the NAS."},
					"content":     map[string]any{"type": "string", "description": "File contents to write."},
					"local_path":  map[string]any{"type": "string", "description": "A local file to upload instead of inline content."},
					"mode":        map[string]any{"type": "string", "description": "Octal permissions, e.g. 0755."},
				},
				"required": []string{"remote_path"},
			},
		},
		{
			"name":        "get_file",
			"description": "Read a file from the TrueNAS via SFTP and return its contents.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"remote_path": map[string]any{"type": "string", "description": "Path on the NAS to read."},
					"max_bytes":   map[string]any{"type": "number", "description": "Max bytes to return (capped at 200KB)."},
				},
				"required": []string{"remote_path"},
			},
		},
	}
}

func handleToolCall(id json.RawMessage, params json.RawMessage) {
	var p struct {
		Name      string         `json:"name"`
		Arguments map[string]any `json:"arguments"`
	}
	_ = json.Unmarshal(params, &p)
	if p.Arguments == nil {
		p.Arguments = map[string]any{}
	}
	var text string
	var isErr bool
	switch p.Name {
	case "run":
		text, isErr = toolRun(p.Arguments)
	case "put_file":
		text, isErr = toolPutFile(p.Arguments)
	case "get_file":
		text, isErr = toolGetFile(p.Arguments)
	default:
		rpcError(id, -32602, "unknown tool: "+p.Name)
		return
	}
	textResult(id, text, isErr)
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			var req rpcReq
			if json.Unmarshal(line, &req) == nil && req.Method != "" {
				dispatch(req)
			}
		}
		if err != nil {
			return
		}
	}
}

func dispatch(req rpcReq) {
	switch req.Method {
	case "initialize":
		var p struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		_ = json.Unmarshal(req.Params, &p)
		pv := p.ProtocolVersion
		if pv == "" {
			pv = "2024-11-05"
		}
		result(req.ID, map[string]any{
			"protocolVersion": pv,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": serverName, "version": serverVersion},
		})
	case "notifications/initialized", "notifications/cancelled":
		// notifications: no response
	case "ping":
		result(req.ID, map[string]any{})
	case "tools/list":
		result(req.ID, map[string]any{"tools": toolsSchema()})
	case "tools/call":
		handleToolCall(req.ID, req.Params)
	default:
		if len(req.ID) > 0 {
			rpcError(req.ID, -32601, "method not found: "+req.Method)
		}
	}
}
