# truenas-mcp — a Claude Code connector for your TrueNAS

A tiny local **MCP server** that gives Claude Code a shell on your TrueNAS, so you stop copy-pasting commands.
It makes an **outbound SSH connection** to the NAS over Tailscale/LAN — nothing listens inbound, no public
endpoint, no OAuth. It runs as a subprocess of Claude Code on your own machine.

Tools it adds: **`run`** (any shell command), **`put_file`** (SFTP upload), **`get_file`** (SFTP read).

## One-time setup
1. **Tailscale** on the NAS and on the machine where you run Claude Code (so the NAS has a private hostname/IP).
2. **An SSH key** (don't reuse a password):
   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/truenas_mcp -C "truenas-mcp"
   ```
   Add the **public** key (`~/.ssh/truenas_mcp.pub`) to the NAS user's authorized keys — in the TrueNAS UI:
   **Credentials → Local Users → (your user) → Authorized Keys**, paste the contents of the `.pub`.
   Confirm it works first:
   ```sh
   ssh -i ~/.ssh/truenas_mcp <user>@<nas-host>
   ```
3. **Drop the binary** somewhere (e.g. `~/bin/truenas-mcp`) and `chmod +x` it.

## Register with Claude Code
Add this to your `.mcp.json` (project root) or user config, filling in your values:
```json
{
  "mcpServers": {
    "truenas": {
      "command": "/absolute/path/to/truenas-mcp",
      "env": {
        "TRUENAS_HOST": "nas-server",
        "TRUENAS_USER": "truenas_admin",
        "TRUENAS_SSH_KEY": "/home/you/.ssh/truenas_mcp"
      }
    }
  }
}
```
Or: `claude mcp add truenas -e TRUENAS_HOST=nas-server -e TRUENAS_USER=truenas_admin -e TRUENAS_SSH_KEY=/home/you/.ssh/truenas_mcp -- /path/to/truenas-mcp`

Restart Claude Code; you'll see `run`, `put_file`, `get_file`. Try: *"run `systemctl status nocturne-server`"*.

## Config (env vars)
| Var | Required | Notes |
|---|---|---|
| `TRUENAS_HOST` | yes | Tailscale hostname or IP |
| `TRUENAS_USER` | yes | e.g. `truenas_admin` or `root` |
| `TRUENAS_PORT` | no | default `22` |
| `TRUENAS_SSH_KEY` | one of | path to a private key (preferred) |
| `TRUENAS_PASSWORD` | one of | alternative to a key |
| `TRUENAS_KNOWN_HOSTS` | no | default `~/.config/truenas-mcp/known_hosts` |

The NAS host key is **pinned on first connect** (trust-on-first-use) and verified thereafter — if it ever changes
the connection is refused (delete it from the known_hosts file if the change is legitimate).

## Security
- This is a **full shell** — Claude can run anything the SSH user can. Prefer a **dedicated NAS user** with only
  the access you need over `root`, and a key you can revoke instantly (remove it from `authorized_keys`).
- stdio + outbound-SSH-over-Tailscale = **no inbound service**, nothing exposed to the internet.
- Tool output is untrusted text (a command can print anything); don't let it auto-drive further destructive
  actions without you confirming.

## Build from source
```sh
go build -o truenas-mcp .                                   # your platform
GOOS=darwin  GOARCH=arm64 go build -o truenas-mcp-mac .     # Apple Silicon
GOOS=linux   GOARCH=amd64 go build -o truenas-mcp-linux .
```
