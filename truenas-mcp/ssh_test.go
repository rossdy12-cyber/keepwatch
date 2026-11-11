package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"encoding/pem"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

// A tiny in-process SSH server that runs exec requests via /bin/sh, so we can test the client end to end.
func startTestServer(t *testing.T, clientPub ssh.PublicKey) string {
	_, hostPriv, _ := ed25519.GenerateKey(rand.Reader)
	hostSigner, err := ssh.NewSignerFromKey(hostPriv)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &ssh.ServerConfig{
		PublicKeyCallback: func(c ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			if string(key.Marshal()) == string(clientPub.Marshal()) {
				return &ssh.Permissions{}, nil
			}
			return nil, os.ErrPermission
		},
	}
	cfg.AddHostKey(hostSigner)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			nc, err := ln.Accept()
			if err != nil {
				return
			}
			go serveConn(nc, cfg)
		}
	}()
	return ln.Addr().String()
}

func serveConn(nc net.Conn, cfg *ssh.ServerConfig) {
	conn, chans, reqs, err := ssh.NewServerConn(nc, cfg)
	if err != nil {
		return
	}
	defer conn.Close()
	go ssh.DiscardRequests(reqs)
	for nch := range chans {
		if nch.ChannelType() != "session" {
			nch.Reject(ssh.UnknownChannelType, "only session")
			continue
		}
		ch, requests, _ := nch.Accept()
		go func() {
			for req := range requests {
				switch req.Type {
				case "exec":
					cmd := string(req.Payload[4 : 4+binary.BigEndian.Uint32(req.Payload)])
					req.Reply(true, nil)
					c := exec.Command("/bin/sh", "-c", cmd)
					out, _ := c.CombinedOutput()
					ch.Write(out)
					code := c.ProcessState.ExitCode()
					ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{uint32(code)}))
					ch.Close()
				case "subsystem":
					name := string(req.Payload[4 : 4+binary.BigEndian.Uint32(req.Payload)])
					if name == "sftp" {
						req.Reply(true, nil)
						if srv, err := sftp.NewServer(ch); err == nil {
							srv.Serve()
						}
						ch.Close()
					} else {
						req.Reply(false, nil)
					}
				default:
					req.Reply(false, nil)
				}
			}
		}()
	}
}

func TestRunOverSSH(t *testing.T) {
	_, clientPriv, _ := ed25519.GenerateKey(rand.Reader)
	signer, err := ssh.NewSignerFromKey(clientPriv)
	if err != nil {
		t.Fatal(err)
	}
	addr := startTestServer(t, signer.PublicKey())

	block, err := ssh.MarshalPrivateKey(clientPriv, "")
	if err != nil {
		t.Fatal(err)
	}
	tmp := t.TempDir()
	keyFile := filepath.Join(tmp, "id")
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(block), 0o600); err != nil {
		t.Fatal(err)
	}

	hostPart, portPart, _ := net.SplitHostPort(addr)
	host, port, user, keyPath, password = hostPart, portPart, "tester", keyFile, ""
	os.Setenv("TRUENAS_KNOWN_HOSTS", filepath.Join(tmp, "known_hosts"))
	sshClient = nil

	out, _ := toolRun(map[string]any{"command": "echo hello && exit 3"})
	if !strings.Contains(out, "hello") {
		t.Fatalf("expected stdout 'hello', got: %s", out)
	}
	if !strings.Contains(out, "\"exit_code\": 3") {
		t.Fatalf("expected exit_code 3, got: %s", out)
	}
	t.Logf("run over SSH OK -> %s", strings.ReplaceAll(out, "\n", " "))

	if b, _ := os.ReadFile(filepath.Join(tmp, "known_hosts")); len(b) == 0 {
		t.Fatal("expected host key pinned in known_hosts")
	}
	t.Log("TOFU host key pinned")

	target := filepath.Join(tmp, "uploaded.txt")
	if msg, e := toolPutFile(map[string]any{"remote_path": target, "content": "hi lauren"}); e {
		t.Fatalf("put_file failed: %s", msg)
	}
	got, e := toolGetFile(map[string]any{"remote_path": target})
	if e || got != "hi lauren" {
		t.Fatalf("get_file mismatch: %q err=%v", got, e)
	}
	t.Log("put_file + get_file round-trip OK")
}
