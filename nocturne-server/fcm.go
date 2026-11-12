package main

// Android push through Firebase Cloud Messaging (HTTP v1 API), using a service-account key file.
// Set FCM_SERVICE_ACCOUNT to the path of the JSON key downloaded from Firebase (Project settings >
// Service accounts > Generate new private key). Without it, Android devices simply don't get push.

import (
	"bytes"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"crypto/rand"
)

type serviceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
	key         *rsa.PrivateKey
}

var (
	fcmMu      sync.Mutex
	fcmSA      *serviceAccount
	fcmLoaded  bool
	fcmAccess  string
	fcmExpires time.Time
	fcmAPIBase = "https://fcm.googleapis.com" // overridden in tests
	fcmCli     = &http.Client{Timeout: 10 * time.Second}
)

func fcmAccount() *serviceAccount {
	fcmMu.Lock()
	defer fcmMu.Unlock()
	if fcmLoaded {
		return fcmSA
	}
	fcmLoaded = true
	var raw []byte
	if j := strings.TrimSpace(os.Getenv("FCM_SERVICE_ACCOUNT_JSON")); j != "" {
		raw = []byte(j)
	} else if p := strings.TrimSpace(os.Getenv("FCM_SERVICE_ACCOUNT")); p != "" {
		b, err := os.ReadFile(p)
		if err != nil {
			fmt.Println("FCM: cannot read service account:", err)
			return nil
		}
		raw = b
	} else {
		return nil
	}
	var sa serviceAccount
	if err := json.Unmarshal(raw, &sa); err != nil || sa.ProjectID == "" || sa.ClientEmail == "" {
		fmt.Println("FCM: service account JSON is not valid")
		return nil
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		fmt.Println("FCM: no private key in service account")
		return nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		fmt.Println("FCM: private key:", err)
		return nil
	}
	k, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		fmt.Println("FCM: private key is not RSA")
		return nil
	}
	sa.key = k
	fcmSA = &sa
	return fcmSA
}

func fcmConfigured() bool { return fcmAccount() != nil }

// fcmToken returns a cached OAuth access token, getting a fresh one with a signed JWT when needed.
func fcmToken(sa *serviceAccount) (string, error) {
	fcmMu.Lock()
	if fcmAccess != "" && time.Until(fcmExpires) > time.Minute {
		t := fcmAccess
		fcmMu.Unlock()
		return t, nil
	}
	fcmMu.Unlock()

	now := time.Now().Unix()
	head := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{
		"iss": sa.ClientEmail, "scope": "https://www.googleapis.com/auth/firebase.messaging",
		"aud": sa.TokenURI, "iat": now, "exp": now + 3600,
	})
	input := head + "." + base64.RawURLEncoding.EncodeToString(claims)
	sum := sha256.Sum256([]byte(input))
	sig, err := rsa.SignPKCS1v15(rand.Reader, sa.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	jwt := input + "." + base64.RawURLEncoding.EncodeToString(sig)

	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {jwt}}
	resp, err := fcmCli.PostForm(sa.TokenURI, form)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != 200 || out.AccessToken == "" {
		return "", fmt.Errorf("token endpoint %d %s", resp.StatusCode, out.Error)
	}
	fcmMu.Lock()
	fcmAccess = out.AccessToken
	fcmExpires = time.Now().Add(time.Duration(out.ExpiresIn) * time.Second)
	fcmMu.Unlock()
	return out.AccessToken, nil
}

var errFCMGone = errors.New("fcm token no longer valid")

// fcmSend sends a data-only, high-priority message; the Android app builds the notification itself.
func fcmSend(deviceToken string, data map[string]string, call bool) error {
	sa := fcmAccount()
	if sa == nil {
		return nil
	}
	access, err := fcmToken(sa)
	if err != nil {
		fmt.Println("FCM auth:", err)
		return err
	}
	ttl := "86400s"
	if call {
		ttl = "60s" // a ring is useless once the caller has given up
	}
	body, _ := json.Marshal(map[string]any{"message": map[string]any{
		"token":   deviceToken,
		"data":    data,
		"android": map[string]any{"priority": "HIGH", "ttl": ttl},
	}})
	req, _ := http.NewRequest("POST", fcmAPIBase+"/v1/projects/"+sa.ProjectID+"/messages:send", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	resp, err := fcmCli.Do(req)
	if err != nil {
		fmt.Println("FCM send:", err)
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 200 {
		return nil
	}
	var e struct {
		Error struct {
			Status  string `json:"status"`
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&e)
	if resp.StatusCode == 404 || e.Error.Status == "NOT_FOUND" || e.Error.Status == "UNREGISTERED" ||
		strings.Contains(e.Error.Message, "not a valid FCM registration token") {
		return errFCMGone
	}
	fmt.Printf("FCM %s... -> %d %s %s\n", safePrefix(deviceToken), resp.StatusCode, e.Error.Status, e.Error.Message)
	return fmt.Errorf("fcm %d", resp.StatusCode)
}
