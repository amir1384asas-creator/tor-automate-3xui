# Tor Automate — Sanaei 3x-ui Edition

Per-country Tor exit routing for **[Sanaei 3x-ui](https://github.com/MHSanaei/3x-ui)** (v3.x).
Migrated from the PasarGuard version; all Tor features and the menu are unchanged, only the panel integration was rewritten against the real 3x-ui API.

Each country becomes its own location in your panel: users connect to a normal inbound, and Xray forwards that inbound's traffic into a local Tor instance that exits in the chosen country.

## Requirements
Debian or Ubuntu · root · Sanaei 3x-ui v3.x already installed and running (tested on **v3.11.0 / Xray 26.10.21**) · at least one TCP-based inbound in the panel (VLESS / VMess / Trojan / Shadowsocks) to use as a template.

## Install

From the extracted project folder:

```bash
sudo bash install.sh
```

One-liner: push this folder to your own GitHub repo, then

```bash
TA_BASE_URL=https://raw.githubusercontent.com/<you>/<repo>/main \
  bash <(curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh)
```

(You can also edit the default `TA_BASE_URL` at the top of `install.sh`.) The installer is safe to re-run; it also serves as an updater.

Then run `sudo tor-automate`:

1. **[5] Bulk Add Nodes** – start the Tor instances (as before).
2. **[9] Panel Sanaei 3x-ui Integration → [1] Auto-Extract** – push them into the panel.

## Panel connection
The panel address is auto-detected with read-only `x-ui setting` calls (port, web base path, TLS certificate, listen IP). For HTTPS the certificate's domain is used and mapped to the local server, so strict TLS verification works. You can also enter any URL manually (e.g. behind a reverse proxy): `https://panel.example.com:2053/mypath`.

| Mode | Notes |
|---|---|
| Username & password | Session login with CSRF handling; automatically re-logs in when the session expires. |
| API token | Panel *Settings → API Tokens*. Use this if you have 2FA (a 2FA code cannot be replayed automatically). Tor Automate never generates or rotates a token itself, because `x-ui setting -getApiToken` invalidates the existing one. |

Credentials are stored in `/etc/tor-automate/panel.conf` (mode 600, root only).

## What "Auto-Extract" does (PasarGuard → 3x-ui mapping)

| PasarGuard | 3x-ui |
|---|---|
| Core config: socks outbound + routing rule | Same objects, written to the Xray template via `/panel/api/xray/update` |
| Cloned core inbound | Cloned **inbound** (new random port, remark `🇩🇪 Germany`, tag `DE-Germany-IN-<port>`) |
| Hosts | 3x-ui **Hosts** (address/SNI/fingerprint cloned from a host you pick; port set to the new inbound's) |
| Users get all hosts automatically | New inbounds **share the existing clients** (same email + Sub ID), so every user's subscription link gains the new locations. Or choose "no users". |
| Core restart + wait | Not needed: 3x-ui applies inbound/outbound/routing changes live |

Safety order: inbounds are created **disabled** → outbounds + routing rules saved → inbounds **enabled**. Traffic can never exit directly from your server's IP through a half-configured location. If the panel rejects the routing update, the new inbounds are removed again. The previous Xray template is backed up to `/etc/tor-automate/backups/` before every change (last 20 kept), and an automatic restore is offered if Xray fails to run afterwards.

Extra panel menu items: **[3] Status, traffic & online clients** (per-location inbound traffic, Tor outbound traffic, local Tor state, panel-wide online count) and **[4] Remove Tor locations from the panel**.

## Files
| Path | Content |
|---|---|
| `/opt/tor-automate/` | program (`tor-automate`, `lib/xui.sh`); launcher `/usr/local/bin/tor-automate` |
| `/etc/tor-automate/` | `panel.conf`, `nodes/` (one torrc per country), `backups/`, `private/` (session cookie) |
| `/var/lib/tor-automate/` | Tor data directories and logs (rotated weekly) |
| `/etc/cron.d/tor-automate` | auto-heal every 30 min **and at boot** |

Nothing under `/usr/local/x-ui`, `/etc/x-ui` or the `x-ui` service is modified. The `tor` package is purged on uninstall **only if Tor Automate installed it**; a pre-existing Tor and its service are left alone.

## Changes from the PasarGuard version
* Tor SOCKS ports now bind to **127.0.0.1** (they were `0.0.0.0`, i.e. an open proxy on the Internet). Xray runs on the same host, so nothing else needs them.
* `runuser` replaces `sudo`; process matching is anchored to this tool's own config paths (the old uninstall `pkill -f node_` could hit unrelated processes).
* Passwords are URL-encoded (previously broke on `&`), and saved with 600 permissions.
* Cron also runs at boot.
* Menu items **[2] Update System** and **[8] Advanced Port Settings** remain "locked" exactly as in the original.

## Limitations
* **3x-ui v3.x only.** Older 3x-ui (v2.x) has no CSRF endpoint / Hosts API / `/panel/api/xray`; the tool reports "no CSRF token" there.
* Tor carries **TCP only**; UDP protocols (Hysteria, WireGuard, TUIC…) cannot be cloned and are not offered.
* Sharing users across inbounds requires every user to have a **Sub ID** in 3x-ui; the tool warns and defaults to "no users" otherwise.
* 3x-ui reports online users **panel-wide**, not per inbound, so per-location online counts are not available (traffic per location is).
* Hosts keep the cloned address but always use the new inbound's port (same as the original did).
* Nodes created by the old PasarGuard version live in `/etc/tor/t_sin_nodes` and are not migrated automatically.

## Testing status
Verified against a live 3x-ui v3.11.0 + Xray 26.10.21 in a sandbox: session login/CSRF/expiry recovery, token mode, HTTPS via `--resolve`, clone with shared clients, host cloning, routing placement, duplicate skip, rollback, removal, status view, and — with a real Xray client — that traffic entering a cloned location is forwarded to the node's SOCKS port while the original inbound is unaffected. The Tor start/stop logic was verified with the real `tor` binary. Full Tor bootstrapping to real exit countries could not be exercised in the sandbox: do a first run on your VPS with one or two countries and check `View Active Nodes` and the panel status screen.
