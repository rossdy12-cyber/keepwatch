package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func newServer(t *testing.T) *httptest.Server {
	t.Helper()
	mu.Lock()
	dataDir = t.TempDir()
	messages, nextID = nil, 0
	tokens = map[string]token{}
	mu.Unlock()
	usersMu.Lock()
	users, usersModTime, usersChecked = nil, time.Time{}, time.Time{}
	usersMu.Unlock()
	authToken = ""
	mux := http.NewServeMux()
	mux.HandleFunc("/api/relay/send", handleSend)
	mux.HandleFunc("/api/relay/messages", handleMessages)
	mux.HandleFunc("/api/push/register", handleRegister)
	mux.HandleFunc("/api/call/ring", handleRing)
	mux.HandleFunc("/api/me", handleMe)
	mux.HandleFunc("/join", handleJoin)
	s := httptest.NewServer(mux)
	t.Cleanup(s.Close)
	return s
}

func call(t *testing.T, s *httptest.Server, method, path, tok, body string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, s.URL+path, strings.NewReader(body))
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func addPeople(t *testing.T) (ross, lauren, mum User) {
	t.Helper()
	var err error
	if ross, err = upsertUser("Ross", []string{"home", "mum"}, true, false); err != nil {
		t.Fatal(err)
	}
	lauren, _ = upsertUser("Lauren", []string{"home"}, false, false)
	mum, _ = upsertUser("Mum", []string{"mum"}, false, false)
	loadUsers(true)
	return
}

func TestRoomsArePrivate(t *testing.T) {
	s := newServer(t)
	ross, lauren, mum := addPeople(t)

	if c, _ := call(t, s, "POST", "/api/relay/send", mum.Token, `{"room":"mum","sender":"Lauren","text":"hi love"}`); c != 200 {
		t.Fatalf("mum send: %d", c)
	}
	// The server stamps the real name, not the claimed one.
	_, b := call(t, s, "GET", "/api/relay/messages?room=mum", ross.Token, "")
	if !strings.Contains(b, `"sender":"Mum"`) || !strings.Contains(b, "hi love") {
		t.Fatalf("ross should read mum's room as Mum: %s", b)
	}
	if c, _ := call(t, s, "GET", "/api/relay/messages?room=mum", lauren.Token, ""); c != 403 {
		t.Fatalf("lauren must not read mum's room, got %d", c)
	}
	if c, _ := call(t, s, "POST", "/api/relay/send", mum.Token, `{"room":"home","text":"x"}`); c != 403 {
		t.Fatalf("mum must not post in home, got %d", c)
	}
	if c, _ := call(t, s, "GET", "/api/relay/messages?room=home", "", ""); c != 401 {
		t.Fatalf("no token must be refused once people exist, got %d", c)
	}
	if c, _ := call(t, s, "GET", "/api/relay/messages?room=home", "nope", ""); c != 401 {
		t.Fatalf("wrong token must be refused, got %d", c)
	}

	_, me := call(t, s, "GET", "/api/me", ross.Token, "")
	var out struct {
		Name  string
		Rooms []struct {
			ID, Title string
			Last      *Msg
		}
	}
	_ = json.Unmarshal([]byte(me), &out)
	if out.Name != "Ross" || len(out.Rooms) != 2 || out.Rooms[0].ID != "home" || out.Rooms[0].Title != "Lauren" ||
		out.Rooms[1].Title != "Mum" || out.Rooms[1].Last == nil || out.Rooms[1].Last.Text != "hi love" {
		t.Fatalf("unexpected /api/me for Ross: %s", me)
	}
	_, me = call(t, s, "GET", "/api/me", mum.Token, "")
	if !strings.Contains(me, `"title":"Ross"`) || strings.Contains(me, `"home"`) {
		t.Fatalf("mum should only see her room with Ross: %s", me)
	}
}

func TestLegacySharedTokenOnlyReachesOriginalRoom(t *testing.T) {
	s := newServer(t)
	authToken = "shared-old"
	if c, _ := call(t, s, "POST", "/api/relay/send", "shared-old", `{"room":"home","sender":"Lauren","text":"before"}`); c != 200 {
		t.Fatalf("legacy send before people exist: %d", c)
	}
	addPeople(t)
	if c, _ := call(t, s, "GET", "/api/relay/messages?room=home", "shared-old", ""); c != 200 {
		t.Fatalf("old shared token should still reach home: %d", c)
	}
	if c, _ := call(t, s, "GET", "/api/relay/messages?room=mum", "shared-old", ""); c != 403 {
		t.Fatalf("old shared token must not reach mum: %d", c)
	}
	_, b := call(t, s, "POST", "/api/relay/send", "shared-old", `{"room":"home","sender":"Lauren","text":"after"}`)
	if !strings.Contains(b, `"id"`) {
		t.Fatal(b)
	}
	_, b = call(t, s, "GET", "/api/relay/messages?room=home", "shared-old", "")
	if !strings.Contains(b, `"sender":"Lauren"`) {
		t.Fatalf("legacy clients keep their own name: %s", b)
	}
}

func TestRoomsSurviveRestart(t *testing.T) {
	s := newServer(t)
	_, _, mum := addPeople(t)
	call(t, s, "POST", "/api/relay/send", mum.Token, `{"room":"mum","text":"saved"}`)
	// An old-format line with no room belongs to "home".
	f, _ := os.OpenFile(logPath(), os.O_APPEND|os.O_WRONLY, 0o600)
	f.WriteString(`{"id":99,"sender":"Lauren","text":"old","ts":1}` + "\n")
	f.Close()
	mu.Lock()
	messages, nextID = nil, 0
	loadState()
	mu.Unlock()
	if len(messages) != 2 || messages[0].Room != "mum" || messages[1].Room != "home" || nextID != 99 {
		t.Fatalf("rooms not restored: %+v next=%d", messages, nextID)
	}
}

func TestPushGoesToOtherMembersOnly(t *testing.T) {
	s := newServer(t)
	ross, lauren, mum := addPeople(t)

	var mu2 sync.Mutex
	var sent []map[string]any
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	pk, _ := x509.MarshalPKCS8PrivateKey(key)
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/token":
			_ = r.ParseForm()
			if r.Form.Get("grant_type") == "" || strings.Count(r.Form.Get("assertion"), ".") != 2 {
				w.WriteHeader(400)
				return
			}
			w.Write([]byte(`{"access_token":"ya29.test","expires_in":3600}`))
		case strings.HasSuffix(r.URL.Path, "/messages:send"):
			if r.Header.Get("Authorization") != "Bearer ya29.test" || !strings.Contains(r.URL.Path, "/projects/nocturne-test/") {
				w.WriteHeader(401)
				return
			}
			var m map[string]any
			_ = json.NewDecoder(r.Body).Decode(&m)
			msg := m["message"].(map[string]any)
			if msg["token"] == "android-gone" {
				w.WriteHeader(404)
				w.Write([]byte(`{"error":{"status":"NOT_FOUND","message":"Requested entity was not found."}}`))
				return
			}
			mu2.Lock()
			sent = append(sent, msg)
			mu2.Unlock()
			w.Write([]byte(`{"name":"projects/nocturne-test/messages/1"}`))
		}
	}))
	defer fake.Close()
	sa, _ := json.Marshal(map[string]string{"type": "service_account", "project_id": "nocturne-test",
		"client_email": "fcm@nocturne-test.iam.gserviceaccount.com", "token_uri": fake.URL + "/token",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pk}))})
	saPath := filepath.Join(dataDir, "sa.json")
	os.WriteFile(saPath, sa, 0o600)
	os.Setenv("FCM_SERVICE_ACCOUNT", saPath)
	defer os.Unsetenv("FCM_SERVICE_ACCOUNT")
	fcmMu.Lock()
	fcmLoaded, fcmSA, fcmAccess = false, nil, ""
	fcmMu.Unlock()
	fcmAPIBase = fake.URL
	if !fcmConfigured() {
		t.Fatal("fcm should be configured")
	}

	call(t, s, "POST", "/api/push/register", mum.Token, `{"token":"android-mum","platform":"android"}`)
	call(t, s, "POST", "/api/push/register", mum.Token, `{"token":"android-gone","platform":"android"}`)
	call(t, s, "POST", "/api/push/register", lauren.Token, `{"token":"android-lauren","platform":"android"}`)
	call(t, s, "POST", "/api/push/register", ross.Token, `{"token":"android-ross","platform":"android"}`)

	pushToRoom("mum", "Ross", "Ross", "tea at 5?", "nocturne://chat/mum", "message")
	if len(sent) != 1 || sent[0]["token"] != "android-mum" {
		t.Fatalf("Ross->mum room should reach only Mum's device, got %+v", sent)
	}
	data := sent[0]["data"].(map[string]any)
	if data["title"] != "Ross" || data["body"] != "tea at 5?" || data["room"] != "mum" || data["kind"] != "message" {
		t.Fatalf("bad data: %+v", data)
	}
	if sent[0]["android"].(map[string]any)["priority"] != "HIGH" {
		t.Fatal("should be high priority")
	}
	mu.Lock()
	_, stillThere := tokens["android-gone"]
	mu.Unlock()
	if stillThere {
		t.Fatal("a device FCM no longer knows should be forgotten")
	}

	sent = nil
	if c, _ := call(t, s, "POST", "/api/call/ring", mum.Token, `{"room":"mum"}`); c != 200 {
		t.Fatal("ring")
	}
	time.Sleep(300 * time.Millisecond)
	mu2.Lock()
	defer mu2.Unlock()
	if len(sent) != 1 || sent[0]["token"] != "android-ross" || sent[0]["data"].(map[string]any)["kind"] != "call" ||
		sent[0]["android"].(map[string]any)["ttl"] != "60s" {
		t.Fatalf("Mum's call should ring only Ross, briefly: %+v", sent)
	}
}

func TestJoinPage(t *testing.T) {
	s := newServer(t)
	_, _, mum := addPeople(t)
	c, b := call(t, s, "GET", "/join?t="+mum.Token, "", "")
	if c != 200 || !strings.Contains(b, "Hello Mum") || !strings.Contains(b, "with Ross") ||
		!strings.Contains(b, "nocturne://setup?server=") || !strings.Contains(b, "/app/nocturne.apk") {
		t.Fatalf("join page: %d %s", c, b)
	}
	if c, _ := call(t, s, "GET", "/join?t=bogus", "", ""); c != 404 {
		t.Fatalf("bad link should 404, got %d", c)
	}
}
