// Nocturne Server — a single self-contained relay for the Nocturne chat apps (iPhone, Android, Windows).
// It does NOT need jarvis-core. One binary provides: the chat relay with per-person logins and private rooms,
// the video-call signalling + call page, native Apple push (APNs) and Android push (Firebase).
//
// Run it on your homelab (TrueNAS). Configure with environment variables (see README).
package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// -------------------------------------------------------------------------------- config

var (
	port       = env("PORT", "8990")
	authToken  = strings.TrimSpace(os.Getenv("AUTH_TOKEN"))
	dataDir    = env("DATA_DIR", "./data")
	apnsKeyID  = strings.TrimSpace(os.Getenv("APNS_KEY_ID"))
	apnsTeamID = env("APNS_TEAM_ID", "G42YL9QS8W")
	apnsBundle = env("APNS_BUNDLE_ID", "com.ross.nocturne")
	apnsEnv    = strings.ToLower(env("APNS_ENV", "auto"))
	turnURL    = strings.TrimSpace(os.Getenv("TURN_URL"))
	turnUser   = strings.TrimSpace(os.Getenv("TURN_USER"))
	turnPass   = strings.TrimSpace(os.Getenv("TURN_PASS"))
)

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func apnsKeyPEM() string {
	if p := os.Getenv("APNS_KEY_P8"); strings.TrimSpace(p) != "" {
		return strings.ReplaceAll(p, "\\n", "\n")
	}
	if f := strings.TrimSpace(os.Getenv("APNS_KEY_FILE")); f != "" {
		if b, err := os.ReadFile(f); err == nil {
			return string(b)
		}
	}
	return ""
}
func apnsConfigured() bool { return apnsKeyPEM() != "" && apnsKeyID != "" }

// -------------------------------------------------------------------------------- state

type Msg struct {
	ID     int64   `json:"id"`
	Sender string  `json:"sender"`
	Text   string  `json:"text"`
	TS     float64 `json:"ts"`
	Room   string  `json:"room"`
}

// A registered push device. User is set for people with a personal token; legacy devices use Room+Name.
type token struct {
	Room     string `json:"room"`
	Name     string `json:"name"`
	User     string `json:"user,omitempty"`
	Platform string `json:"platform,omitempty"` // "ios" (APNs, default) or "android" (FCM)
}

var (
	mu       sync.Mutex
	messages []Msg
	nextID   int64
	tokens   = map[string]token{} // deviceToken -> {room,name}
	presence = map[string]float64{}
)

// -------------------------------------------------------------------------------- main

func main() {
	if runCLI(os.Args[1:]) {
		return
	}
	_ = os.MkdirAll(dataDir, 0o700)
	loadState()
	loadUsers(true)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/api/relay/send", handleSend)
	mux.HandleFunc("/api/relay/messages", handleMessages)
	mux.HandleFunc("/api/relay/seen", handleSeen)
	mux.HandleFunc("/api/relay/presence", handlePresence)
	mux.HandleFunc("/api/push/register", handleRegister)
	mux.HandleFunc("/api/call/ring", handleRing)
	mux.HandleFunc("/api/call/stream", handleCallStream)
	mux.HandleFunc("/api/call/signal", handleCallSignal)
	mux.HandleFunc("/call/config", handleCallConfig)
	mux.HandleFunc("/call", handleCallPage)
	mux.HandleFunc("/api/me", handleMe)
	mux.HandleFunc("/join", handleJoin)
	mux.HandleFunc("/app/nocturne.apk", handleAPK)

	addr := ":" + port
	fmt.Printf("Nocturne Server on %s  (APNs: %v, FCM: %v, people: %d)\n", addr, apnsConfigured(), fcmConfigured(), len(usersSnapshot()))
	srv := &http.Server{Addr: addr, Handler: logReqs(mux), ReadHeaderTimeout: 10 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		fmt.Println("server stopped:", err)
	}
}

func logReqs(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(204)
			return
		}
		h.ServeHTTP(w, r)
	})
}

// allow authenticates the request and checks it may use `room`; it writes the error itself.
func allow(w http.ResponseWriter, r *http.Request, room string) (identity, bool) {
	id, ok := whoami(r)
	if !ok {
		http.Error(w, "unauthorized", 401)
		return id, false
	}
	if room != "" && !id.can(room) {
		http.Error(w, "not your conversation", 403)
		return id, false
	}
	return id, true
}

// -------------------------------------------------------------------------------- relay

func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{"status": "ok", "push": apnsConfigured(), "fcm": fcmConfigured()})
}

func handleSend(w http.ResponseWriter, r *http.Request) {
	var in struct{ Room, Sender, Text string }
	_ = json.NewDecoder(r.Body).Decode(&in)
	room := clip(orDef(in.Room, "home"), 64)
	id, ok := allow(w, r, room)
	if !ok {
		return
	}
	in.Text = strings.TrimSpace(in.Text)
	if in.Text == "" {
		http.Error(w, "empty", 400)
		return
	}
	sender := id.displayName(in.Sender)
	mu.Lock()
	nextID++
	m := Msg{ID: nextID, Sender: sender, Text: clip(in.Text, 4000), TS: nowUnix(), Room: room}
	messages = append(messages, m)
	appendLog(m)
	mu.Unlock()
	go pushToRoom(room, sender, sender, clip(in.Text, 200), "nocturne://chat/"+room, "message")
	writeJSON(w, map[string]any{"id": m.ID, "ts": m.TS})
}

func handleMessages(w http.ResponseWriter, r *http.Request) {
	room := orDef(r.URL.Query().Get("room"), "home")
	if _, ok := allow(w, r, room); !ok {
		return
	}
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	out := []Msg{}
	mu.Lock()
	for _, m := range messages {
		if m.Room == room && m.ID > since {
			out = append(out, m)
			if len(out) >= 200 {
				break
			}
		}
	}
	mu.Unlock()
	writeJSON(w, out)
}

func handleSeen(w http.ResponseWriter, r *http.Request) {
	var in struct{ Room, Who string }
	_ = json.NewDecoder(r.Body).Decode(&in)
	room := orDef(in.Room, "home")
	id, ok := allow(w, r, room)
	if !ok {
		return
	}
	mu.Lock()
	presence[room+"\x00"+id.displayName(in.Who)] = nowUnix()
	mu.Unlock()
	writeJSON(w, map[string]any{"ok": true})
}

func handlePresence(w http.ResponseWriter, r *http.Request) {
	room := orDef(r.URL.Query().Get("room"), "home")
	if _, ok := allow(w, r, room); !ok {
		return
	}
	now := nowUnix()
	out := []map[string]any{}
	mu.Lock()
	for k, ts := range presence {
		parts := strings.SplitN(k, "\x00", 2)
		if len(parts) == 2 && parts[0] == room {
			out = append(out, map[string]any{"who": parts[1], "ts": ts, "ago": int(now - ts)})
		}
	}
	mu.Unlock()
	writeJSON(w, out)
}

// -------------------------------------------------------------------------------- push registration + APNs

func handleRegister(w http.ResponseWriter, r *http.Request) {
	id, ok := allow(w, r, "")
	if !ok {
		return
	}
	var in struct{ Token, Room, Name, Platform string }
	_ = json.NewDecoder(r.Body).Decode(&in)
	if strings.TrimSpace(in.Token) == "" {
		http.Error(w, "missing token", 400)
		return
	}
	platform := "ios"
	if strings.EqualFold(in.Platform, "android") {
		platform = "android"
	}
	rec := token{Room: clip(orDef(in.Room, "home"), 64), Name: id.displayName(in.Name), User: id.name, Platform: platform}
	if id.name == "" && !id.can(rec.Room) {
		http.Error(w, "not your conversation", 403)
		return
	}
	mu.Lock()
	tokens[in.Token] = rec
	saveTokens()
	mu.Unlock()
	writeJSON(w, map[string]any{"ok": true, "push": apnsConfigured(), "fcm": fcmConfigured()})
}

func handleRing(w http.ResponseWriter, r *http.Request) {
	var in struct{ Room, Caller string }
	_ = json.NewDecoder(r.Body).Decode(&in)
	room := orDef(in.Room, "home")
	id, ok := allow(w, r, room)
	if !ok {
		return
	}
	caller := id.displayName(in.Caller)
	go pushToRoom(room, caller, caller+" is calling", "Incoming video call", "nocturne://call/"+room, "call")
	writeJSON(w, map[string]any{"ok": true})
}

// pushToRoom notifies every device of the room's other members (personal tokens) or, for legacy devices,
// every device registered to the room under a different name.
func pushToRoom(room, sender, title, body, url, kind string) {
	type target struct{ tok, platform string }
	var targets []target
	mu.Lock()
	for tok, t := range tokens {
		var match bool
		if t.User != "" {
			match = t.User != sender && userInRoom(t.User, room)
		} else {
			match = t.Room == room && t.Name != sender
		}
		if match {
			targets = append(targets, target{tok, t.Platform})
		}
	}
	mu.Unlock()
	for _, t := range targets {
		if t.platform == "android" {
			data := map[string]string{"kind": kind, "room": room, "title": title, "body": body, "url": url,
				"sender": sender, "roomTitle": sender}
			if err := fcmSend(t.tok, data, kind == "call"); err == errFCMGone {
				mu.Lock()
				delete(tokens, t.tok)
				saveTokens()
				mu.Unlock()
			}
		} else if apnsConfigured() {
			apnsPush(t.tok, title, body, url)
		}
	}
}

var (
	jwtMu   sync.Mutex
	jwtTok  string
	jwtIat  int64
	apnsCli = &http.Client{Timeout: 10 * time.Second}
)

func apnsBearer() string {
	jwtMu.Lock()
	defer jwtMu.Unlock()
	now := time.Now().Unix()
	if jwtTok != "" && now-jwtIat < 2400 {
		return jwtTok
	}
	block, _ := pem.Decode([]byte(apnsKeyPEM()))
	if block == nil {
		return ""
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		fmt.Println("APNs key parse:", err)
		return ""
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		fmt.Println("APNs key is not EC")
		return ""
	}
	header := b64(fmt.Sprintf(`{"alg":"ES256","kid":"%s"}`, apnsKeyID))
	claims := b64(fmt.Sprintf(`{"iss":"%s","iat":%d}`, apnsTeamID, now))
	signingInput := header + "." + claims
	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return ""
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	jwtTok = signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
	jwtIat = now
	return jwtTok
}

func apnsHosts() []string {
	switch apnsEnv {
	case "production":
		return []string{"https://api.push.apple.com"}
	case "sandbox":
		return []string{"https://api.sandbox.push.apple.com"}
	default:
		return []string{"https://api.push.apple.com", "https://api.sandbox.push.apple.com"}
	}
}

func apnsPush(deviceToken, title, body, url string) {
	bearer := apnsBearer()
	if bearer == "" {
		return
	}
	payload := map[string]any{"aps": map[string]any{
		"alert": map[string]string{"title": title, "body": body}, "sound": "default"}}
	if url != "" {
		payload["url"] = url
	}
	data, _ := json.Marshal(payload)
	hosts := apnsHosts()
	for i, host := range hosts {
		req, _ := http.NewRequest("POST", host+"/3/device/"+deviceToken, strings.NewReader(string(data)))
		req.Header.Set("authorization", "bearer "+bearer)
		req.Header.Set("apns-topic", apnsBundle)
		req.Header.Set("apns-push-type", "alert")
		req.Header.Set("apns-priority", "10")
		resp, err := apnsCli.Do(req)
		if err != nil {
			fmt.Println("APNs send:", err)
			return
		}
		reason := ""
		if resp.StatusCode != 200 {
			var e struct{ Reason string }
			_ = json.NewDecoder(resp.Body).Decode(&e)
			reason = e.Reason
		}
		resp.Body.Close()
		if resp.StatusCode == 200 {
			return
		}
		if resp.StatusCode == 410 || reason == "Unregistered" {
			mu.Lock()
			delete(tokens, deviceToken)
			saveTokens()
			mu.Unlock()
			return
		}
		if reason == "BadDeviceToken" && i < len(hosts)-1 {
			continue // wrong environment — try the other APNs host
		}
		fmt.Printf("APNs %s... -> %d %s\n", safePrefix(deviceToken), resp.StatusCode, reason)
		return
	}
}

// -------------------------------------------------------------------------------- call signalling (SSE)

type sseHub struct {
	mu    sync.Mutex
	rooms map[string]map[chan string]string // channel -> client id
}

var hub = &sseHub{rooms: map[string]map[chan string]string{}}

func (h *sseHub) add(room, id string) chan string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.rooms[room] == nil {
		h.rooms[room] = map[chan string]string{}
	}
	ch := make(chan string, 16)
	h.rooms[room][ch] = id
	return ch
}
func (h *sseHub) remove(room string, ch chan string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if m := h.rooms[room]; m != nil {
		delete(m, ch)
		if len(m) == 0 {
			delete(h.rooms, room)
		}
	}
}
func (h *sseHub) broadcast(room, fromID, msg string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch, id := range h.rooms[room] {
		if id != fromID {
			select {
			case ch <- msg:
			default:
			}
		}
	}
}

func handleCallStream(w http.ResponseWriter, r *http.Request) {
	room := r.URL.Query().Get("room")
	if _, ok := allow(w, r, room); !ok {
		return
	}
	id := r.URL.Query().Get("id")
	flusher, ok := w.(http.Flusher)
	if room == "" || !ok {
		http.Error(w, "no stream", 400)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	ch := hub.add(room, id)
	defer hub.remove(room, ch)
	fmt.Fprint(w, "retry: 2000\n\n")
	flusher.Flush()
	keepalive := time.NewTicker(25 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case msg := <-ch:
			fmt.Fprintf(w, "data: %s\n\n", msg)
			flusher.Flush()
		case <-keepalive.C:
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

func handleCallSignal(w http.ResponseWriter, r *http.Request) {
	room := r.URL.Query().Get("room")
	if _, ok := allow(w, r, room); !ok {
		return
	}
	id := r.URL.Query().Get("id")
	body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	hub.broadcast(room, id, string(body))
	writeJSON(w, map[string]any{"ok": true})
}

func handleCallConfig(w http.ResponseWriter, r *http.Request) {
	ice := []map[string]any{{"urls": "stun:stun.l.google.com:19302"}}
	if turnURL != "" {
		ice = append(ice, map[string]any{"urls": turnURL, "username": turnUser, "credential": turnPass})
	}
	writeJSON(w, map[string]any{"iceServers": ice})
}

func handleCallPage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, callHTML)
}

// -------------------------------------------------------------------------------- persistence (plain files)

func logPath() string    { return filepath.Join(dataDir, "messages.jsonl") }
func tokensPath() string { return filepath.Join(dataDir, "tokens.json") }

func appendLog(m Msg) {
	f, err := os.OpenFile(logPath(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	b, _ := json.Marshal(m)
	f.Write(append(b, '\n'))
}

func loadState() {
	if f, err := os.Open(logPath()); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1024*64), 1024*256)
		for sc.Scan() {
			var m Msg
			if json.Unmarshal(sc.Bytes(), &m) == nil {
				if m.Room == "" {
					m.Room = "home" // lines written before rooms were saved belong to the original room
				}
				messages = append(messages, m)
				if m.ID > nextID {
					nextID = m.ID
				}
			}
		}
		f.Close()
	}
	if b, err := os.ReadFile(tokensPath()); err == nil {
		_ = json.Unmarshal(b, &tokens)
	}
}

func saveTokens() {
	b, _ := json.MarshalIndent(tokens, "", "  ")
	_ = os.WriteFile(tokensPath(), b, 0o600)
}

// -------------------------------------------------------------------------------- helpers

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
func orDef(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}
func clip(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
func nowUnix() float64 { return float64(time.Now().UnixNano()) / 1e9 }
func b64(s string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(s))
}
func safePrefix(s string) string {
	if len(s) > 8 {
		return s[:8]
	}
	return s
}
