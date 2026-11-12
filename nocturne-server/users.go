package main

// People and conversations ("rooms"). Each person has their own token and can only reach their own rooms:
// e.g. Ross -> [home, mum], Lauren -> [home], Mum -> [mum]. Stored in DATA_DIR/users.json and managed with
// the CLI (`nocturne-server adduser ...`); the server picks up changes without a restart.
//
// Without a users.json the server behaves as before: one shared AUTH_TOKEN (or none) for every room.

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type User struct {
	Name  string   `json:"name"`
	Token string   `json:"token"`
	Rooms []string `json:"rooms"`
	Admin bool     `json:"admin,omitempty"`
}

var (
	usersMu      sync.RWMutex
	users        []User
	usersModTime time.Time
	usersChecked time.Time
	legacyRooms  = splitList(env("LEGACY_ROOMS", "home"))
)

func usersPath() string { return env("USERS_FILE", filepath.Join(dataDir, "users.json")) }

// loadUsers (re)reads users.json when it changed. Cheap enough to call per request (stat at most every 2s).
func loadUsers(force bool) {
	usersMu.Lock()
	defer usersMu.Unlock()
	if !force && time.Since(usersChecked) < 2*time.Second {
		return
	}
	usersChecked = time.Now()
	st, err := os.Stat(usersPath())
	if err != nil {
		users, usersModTime = nil, time.Time{}
		return
	}
	if !force && st.ModTime().Equal(usersModTime) {
		return
	}
	b, err := os.ReadFile(usersPath())
	if err != nil {
		return
	}
	var f struct {
		Users []User `json:"users"`
	}
	if json.Unmarshal(b, &f) == nil {
		users, usersModTime = f.Users, st.ModTime()
	}
}

func saveUsers(list []User) error {
	b, _ := json.MarshalIndent(map[string]any{"users": list}, "", "  ")
	tmp := usersPath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, usersPath())
}

func usersSnapshot() []User {
	loadUsers(false)
	usersMu.RLock()
	defer usersMu.RUnlock()
	out := make([]User, len(users))
	copy(out, users)
	return out
}

// identity is who made a request. name == "" means a legacy/shared-token client whose self-reported
// name is trusted (the old behaviour). rooms == nil means every room.
type identity struct {
	name  string
	admin bool
	rooms map[string]bool
}

func (id identity) can(room string) bool { return id.rooms == nil || id.rooms[room] }
func (id identity) displayName(claimed string) string {
	if id.name != "" {
		return id.name
	}
	return clip(orDef(claimed, "Someone"), 64)
}

func requestToken(r *http.Request) string {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
	}
	return strings.TrimSpace(r.URL.Query().Get("token"))
}

func eq(a, b string) bool { return a != "" && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

func whoami(r *http.Request) (identity, bool) {
	tok := requestToken(r)
	list := usersSnapshot()
	for _, u := range list {
		if eq(tok, u.Token) {
			return identity{name: u.Name, admin: u.Admin, rooms: set(u.Rooms)}, true
		}
	}
	if authToken != "" {
		if !eq(tok, authToken) {
			return identity{}, false
		}
		if len(list) > 0 {
			return identity{rooms: set(legacyRooms)}, true // old shared token: only the original room(s)
		}
		return identity{}, true
	}
	if len(list) > 0 {
		return identity{}, false // people are configured, so a personal token is required
	}
	return identity{}, true // no auth configured at all (old behaviour)
}

func userByToken(tok string) (User, bool) {
	for _, u := range usersSnapshot() {
		if eq(tok, u.Token) {
			return u, true
		}
	}
	return User{}, false
}

func membersOf(room string) []string {
	var out []string
	for _, u := range usersSnapshot() {
		for _, r := range u.Rooms {
			if r == room {
				out = append(out, u.Name)
				break
			}
		}
	}
	return out
}

func userInRoom(name, room string) bool {
	for _, m := range membersOf(room) {
		if m == name {
			return true
		}
	}
	return false
}

// roomTitle is what `viewer` calls a room: the other people in it ("Lauren"), or the room id.
func roomTitle(room, viewer string) string {
	var others []string
	for _, m := range membersOf(room) {
		if m != viewer {
			others = append(others, m)
		}
	}
	if len(others) == 0 {
		return room
	}
	return strings.Join(others, " & ")
}

// ---------------------------------------------------------------- GET /api/me

func handleMe(w http.ResponseWriter, r *http.Request) {
	id, ok := whoami(r)
	if !ok {
		http.Error(w, "unauthorized", 401)
		return
	}
	var ids []string
	if id.rooms != nil {
		for room := range id.rooms {
			ids = append(ids, room)
		}
	}
	sort.Strings(ids)
	rooms := []map[string]any{}
	mu.Lock()
	for _, room := range ids {
		entry := map[string]any{"id": room, "title": roomTitle(room, id.name), "members": membersOf(room), "last": nil}
		for i := len(messages) - 1; i >= 0; i-- {
			if messages[i].Room == room {
				entry["last"] = messages[i]
				break
			}
		}
		rooms = append(rooms, entry)
	}
	mu.Unlock()
	writeJSON(w, map[string]any{"name": id.name, "admin": id.admin, "rooms": rooms,
		"push": map[string]bool{"apns": apnsConfigured(), "fcm": fcmConfigured()}})
}

// ---------------------------------------------------------------- CLI helpers

func newToken() string {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func upsertUser(name string, rooms []string, admin, rotate bool) (User, error) {
	name = strings.TrimSpace(name)
	if name == "" || len(rooms) == 0 {
		return User{}, errors.New("need a name and at least one room")
	}
	loadUsers(true)
	list := usersSnapshot()
	for i := range list {
		if strings.EqualFold(list[i].Name, name) {
			list[i].Rooms, list[i].Admin = rooms, admin
			if rotate || list[i].Token == "" {
				list[i].Token = newToken()
			}
			return list[i], saveUsers(list)
		}
	}
	u := User{Name: name, Token: newToken(), Rooms: rooms, Admin: admin}
	return u, saveUsers(append(list, u))
}

func deleteUser(name string) error {
	loadUsers(true)
	list := usersSnapshot()
	for i := range list {
		if strings.EqualFold(list[i].Name, name) {
			return saveUsers(append(list[:i], list[i+1:]...))
		}
	}
	return errors.New("no such person")
}

func findUser(name string) (User, bool) {
	loadUsers(true)
	for _, u := range usersSnapshot() {
		if strings.EqualFold(u.Name, name) {
			return u, true
		}
	}
	return User{}, false
}

func set(list []string) map[string]bool {
	m := map[string]bool{}
	for _, s := range list {
		if s = strings.TrimSpace(s); s != "" {
			m[s] = true
		}
	}
	return m
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
