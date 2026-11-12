package main

// Onboarding: each person gets a personal link (https://<server>/join?t=<their token>). Opening it on their
// phone shows a crimson page with (1) the Android app download and (2) a button that opens Nocturne and signs
// them in (nocturne://setup?server=...&token=...). Works for the iPhone app too.

import (
	"fmt"
	"html"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

var (
	publicURL = strings.TrimRight(strings.TrimSpace(os.Getenv("PUBLIC_URL")), "/")
	apkURL    = strings.TrimSpace(os.Getenv("APK_URL")) // default: this server's /app/nocturne.apk
)

func baseURL(r *http.Request) string {
	if publicURL != "" {
		return publicURL
	}
	scheme := "https"
	if p := r.Header.Get("X-Forwarded-Proto"); p != "" {
		scheme = p
	} else if r.TLS == nil && strings.HasPrefix(r.Host, "localhost") {
		scheme = "http"
	}
	return scheme + "://" + r.Host
}

func joinLink(base, token string) string { return base + "/join?t=" + url.QueryEscape(token) }

func setupLink(base, token string) string {
	return "nocturne://setup?server=" + url.QueryEscape(base) + "&token=" + url.QueryEscape(token)
}

func handleJoin(w http.ResponseWriter, r *http.Request) {
	tok := r.URL.Query().Get("t")
	u, ok := userByToken(tok)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	if !ok {
		w.WriteHeader(404)
		fmt.Fprint(w, page("Link not recognised", `<p>This invitation link isn't valid any more. Ask for a new one.</p>`))
		return
	}
	base := baseURL(r)
	apk := apkURL
	if apk == "" {
		apk = base + "/app/nocturne.apk"
	}
	var with []string
	for _, room := range u.Rooms {
		with = append(with, roomTitle(room, u.Name))
	}
	body := fmt.Sprintf(`
<p class="lead">Hello %s. Nocturne is your private chat%s.</p>
<ol>
  <li><b>Android:</b> <a class="btn ghost" href="%s">Download the app</a>
      <small>If asked, allow your browser to install apps, then tap Install.</small></li>
  <li><b>iPhone:</b> install Nocturne from the Stark Store.</li>
  <li>Come back to this page and tap:<br><a class="btn" href="%s">Open Nocturne and sign in</a></li>
</ol>
<p><small>Keep this link to yourself — it signs in as you.</small></p>`,
		html.EscapeString(u.Name), withText(with), html.EscapeString(apk), html.EscapeString(setupLink(base, tok)))
	fmt.Fprint(w, page("Join Nocturne", body))
}

func withText(names []string) string {
	if len(names) == 0 {
		return ""
	}
	return " with " + html.EscapeString(strings.Join(names, " and "))
}

func handleAPK(w http.ResponseWriter, r *http.Request) {
	p := filepath.Join(dataDir, "nocturne.apk")
	if _, err := os.Stat(p); err != nil {
		if apkURL != "" {
			http.Redirect(w, r, apkURL, http.StatusFound)
			return
		}
		http.Error(w, "The Android app hasn't been uploaded to this server yet.", 404)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.android.package-archive")
	w.Header().Set("Content-Disposition", `attachment; filename="nocturne.apk"`)
	http.ServeFile(w, r, p)
}

func page(title, body string) string {
	return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>` + html.EscapeString(title) + `</title><style>
body{margin:0;background:#0a0506;color:#f0e6e8;font:17px/1.5 Georgia,serif;padding:28px 20px}
h1{color:#e8415c;font-size:28px;margin:0 0 14px} .lead{font-size:19px}
ol{padding-left:22px} li{margin:0 0 18px} small{display:block;color:#9a8288;font-size:14px;margin-top:6px}
.btn{display:inline-block;margin-top:8px;background:#c01030;color:#fff;text-decoration:none;padding:13px 20px;
 border-radius:12px;font:600 17px -apple-system,Roboto,sans-serif}
.btn.ghost{background:transparent;border:1px solid #c01030;color:#e8415c}
</style></head><body><h1>` + html.EscapeString(title) + `</h1>` + body + `</body></html>`
}

// ---------------------------------------------------------------- CLI: manage people

func runCLI(args []string) bool {
	if len(args) == 0 {
		return false
	}
	base := publicURL
	var rest []string
	admin, rotate := false, false
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--admin":
			admin = true
		case "--new-token":
			rotate = true
		case "--url":
			if i+1 < len(args) {
				base = strings.TrimRight(args[i+1], "/")
				i++
			}
		default:
			rest = append(rest, args[i])
		}
	}
	_ = os.MkdirAll(dataDir, 0o700)
	switch rest[0] {
	case "adduser":
		if len(rest) < 3 {
			fmt.Println("usage: nocturne-server adduser <Name> <room>[,<room>...] [--admin] [--new-token] [--url https://server]")
			os.Exit(2)
		}
		u, err := upsertUser(rest[1], splitList(rest[2]), admin, rotate)
		if err != nil {
			fmt.Println("error:", err)
			os.Exit(1)
		}
		printUser(u, base)
	case "link":
		if len(rest) < 2 {
			fmt.Println("usage: nocturne-server link <Name> [--url https://server]")
			os.Exit(2)
		}
		u, ok := findUser(rest[1])
		if !ok {
			fmt.Println("no such person")
			os.Exit(1)
		}
		printUser(u, base)
	case "deluser":
		if len(rest) < 2 || deleteUser(rest[1]) != nil {
			fmt.Println("usage: nocturne-server deluser <Name>  (and the name must exist)")
			os.Exit(1)
		}
		fmt.Println("removed", rest[1])
	case "users":
		loadUsers(true)
		for _, u := range usersSnapshot() {
			fmt.Printf("%-12s rooms=%s%s\n", u.Name, strings.Join(u.Rooms, ","), map[bool]string{true: "  (admin)"}[u.Admin])
		}
	default:
		return false
	}
	return true
}

func printUser(u User, base string) {
	fmt.Printf("%s  rooms=%s\n", u.Name, strings.Join(u.Rooms, ","))
	if base == "" {
		fmt.Println("token:", u.Token)
		fmt.Println("(set PUBLIC_URL or pass --url https://your-server to print the join link)")
		return
	}
	fmt.Println("join link:", joinLink(base, u.Token))
}
