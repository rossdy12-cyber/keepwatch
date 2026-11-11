// Nocturne Chat — a tiny standalone Windows (and Mac/Linux) client for the self-hosted Nocturne chat relay.
// Double-click the .exe: it starts a local server, opens your browser to a gothic chat UI, and talks to your
// jarvis-core relay. No install, no dependencies.
package main

import (
	"bytes"
	"crypto/tls"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

//go:embed ui/chat.html
var uiFiles embed.FS

// Config is what the user sets once; stored next to the OS config dir.
type Config struct {
	RelayURL    string `json:"relayURL"`
	Token       string `json:"token"`
	DisplayName string `json:"displayName"`
	PartnerName string `json:"partnerName"`
	Room        string `json:"room"`
}

func configPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir, _ = os.UserHomeDir()
	}
	d := filepath.Join(dir, "nocturne-chat")
	_ = os.MkdirAll(d, 0o700)
	return filepath.Join(d, "config.json")
}

func loadConfig() Config {
	var c Config
	b, err := os.ReadFile(configPath())
	if err == nil {
		_ = json.Unmarshal(b, &c)
	}
	if c.Room == "" {
		c.Room = "home"
	}
	if c.DisplayName == "" {
		c.DisplayName = "Me"
	}
	return c
}

func saveConfig(c Config) error {
	b, _ := json.MarshalIndent(c, "", "  ")
	return os.WriteFile(configPath(), b, 0o600)
}

// normalizeBase turns "jarvis.nas-server.co.uk" into "https://jarvis.nas-server.co.uk" and trims a trailing slash.
func normalizeBase(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	low := strings.ToLower(s)
	if !strings.HasPrefix(low, "http://") && !strings.HasPrefix(low, "https://") {
		s = "https://" + s
	}
	return strings.TrimRight(s, "/")
}

// The relay may use a self-signed homelab cert; this is the user's own server, so trust it (same as the app).
var httpClient = &http.Client{
	Timeout:   20 * time.Second,
	Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
}

func main() {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Println("Could not start:", err)
		return
	}
	port := ln.Addr().(*net.TCPAddr).Port
	addr := fmt.Sprintf("http://127.0.0.1:%d", port)

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleIndex)
	mux.HandleFunc("/api/config", handleConfig)
	mux.HandleFunc("/api/messages", handleMessages)
	mux.HandleFunc("/api/send", handleSend)
	mux.HandleFunc("/api/ring", handleRing)

	fmt.Println("Nocturne Chat running at", addr)
	fmt.Println("Keep this window open while you chat. Close it to quit.")
	go func() { time.Sleep(400 * time.Millisecond); openBrowser(addr) }()
	_ = http.Serve(ln, mux)
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	b, _ := uiFiles.ReadFile("ui/chat.html")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(b)
}

// handleConfig: GET returns the current config (+ computed call URL); POST saves a new config.
func handleConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		var c Config
		if err := json.NewDecoder(r.Body).Decode(&c); err != nil {
			http.Error(w, "bad config", 400)
			return
		}
		c.RelayURL = normalizeBase(c.RelayURL)
		if c.Room == "" {
			c.Room = "home"
		}
		if err := saveConfig(c); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, map[string]any{"ok": true})
		return
	}
	c := loadConfig()
	base := normalizeBase(c.RelayURL)
	callURL := ""
	if base != "" {
		q := url.Values{}
		q.Set("room", c.Room)
		q.Set("name", c.DisplayName)
		q.Set("with", c.PartnerName)
		q.Set("token", c.Token)
		callURL = base + "/call?" + q.Encode()
	}
	writeJSON(w, map[string]any{
		"relayURL": c.RelayURL, "token": c.Token, "displayName": c.DisplayName,
		"partnerName": c.PartnerName, "room": c.Room,
		"configured": base != "", "callURL": callURL,
	})
}

// handleMessages proxies GET /api/relay/messages?room=&since= to the relay.
func handleMessages(w http.ResponseWriter, r *http.Request) {
	c := loadConfig()
	base := normalizeBase(c.RelayURL)
	if base == "" {
		writeJSON(w, []any{})
		return
	}
	since := r.URL.Query().Get("since")
	if since == "" {
		since = "0"
	}
	u := fmt.Sprintf("%s/api/relay/messages?room=%s&since=%s", base, url.QueryEscape(c.Room), url.QueryEscape(since))
	req, _ := http.NewRequest("GET", u, nil)
	addAuth(req, c)
	resp, err := httpClient.Do(req)
	if err != nil {
		http.Error(w, "relay unreachable", 502)
		return
	}
	defer resp.Body.Close()
	w.Header().Set("Content-Type", "application/json")
	_, _ = io.Copy(w, resp.Body)
}

// handleSend proxies a message to POST /api/relay/send.
func handleSend(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Text string `json:"text"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	c := loadConfig()
	base := normalizeBase(c.RelayURL)
	if base == "" || strings.TrimSpace(body.Text) == "" {
		http.Error(w, "not ready", 400)
		return
	}
	payload, _ := json.Marshal(map[string]string{"room": c.Room, "sender": c.DisplayName, "text": body.Text})
	proxyPost(w, base+"/api/relay/send", payload, c)
}

// handleRing proxies a call ring to POST /api/call/ring.
func handleRing(w http.ResponseWriter, r *http.Request) {
	c := loadConfig()
	base := normalizeBase(c.RelayURL)
	if base == "" {
		http.Error(w, "not ready", 400)
		return
	}
	payload, _ := json.Marshal(map[string]string{"room": c.Room, "caller": c.DisplayName})
	proxyPost(w, base+"/api/call/ring", payload, c)
}

func proxyPost(w http.ResponseWriter, u string, payload []byte, c Config) {
	req, _ := http.NewRequest("POST", u, bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	addAuth(req, c)
	resp, err := httpClient.Do(req)
	if err != nil {
		http.Error(w, "relay unreachable", 502)
		return
	}
	defer resp.Body.Close()
	w.Header().Set("Content-Type", "application/json")
	_, _ = io.Copy(w, resp.Body)
}

func addAuth(req *http.Request, c Config) {
	if strings.TrimSpace(c.Token) != "" {
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(c.Token))
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func openBrowser(u string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	case "darwin":
		cmd = exec.Command("open", u)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	_ = cmd.Start()
}
