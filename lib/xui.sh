#!/usr/bin/env bash
# lib/xui.sh - Sanaei 3x-ui (v3.x) API client for Tor Automate.
#
# Verified against the 3x-ui source (internal/web/controller) and a live v3.11.0 panel:
#   * session login : GET  {base}/csrf-token  ->  POST {base}/login (X-CSRF-Token header)
#                     cookie "3x-ui" (path = web base path); login failure = HTTP 200 + success:false
#   * every POST needs the X-CSRF-Token header in session mode (403 otherwise)
#   * expired session = HTTP 401, but ONLY when "X-Requested-With: XMLHttpRequest" is sent
#     (otherwise the panel answers 404, which is indistinguishable from a wrong base path)
#   * API token mode : "Authorization: Bearer <token>" skips CSRF entirely
#   * envelope       : {"success":bool,"msg":str,"obj":any}
#
# This file only defines functions; it is meant to be sourced.
# Required globals (normally loaded from panel.conf by xui_load_conf):
#   PANEL_URL      full base URL incl. web base path, no trailing slash  (https://host:2053/abc)
#   AUTH_MODE      session | token
#   PANEL_USER / PANEL_PASS   (session mode)      API_TOKEN (token mode)
#   PANEL_RESOLVE  optional curl --resolve value  (host:port:ip)
#   PANEL_INSECURE 1 = skip TLS verification (-k)
# State directory: XUI_STATE_DIR (cookie jar + csrf token, mode 700).

XUI_STATE_DIR="${XUI_STATE_DIR:-/etc/tor-automate/private}"
XUI_LAST_ERR=""

xui_load_conf() {
    local f="${1:-$PANEL_CONF}"
    [ -r "$f" ] || return 1
    PANEL_URL="" AUTH_MODE="" PANEL_USER="" PANEL_PASS="" API_TOKEN="" PANEL_RESOLVE="" PANEL_INSECURE=0
    # Parse KEY='value' lines ourselves instead of 'source' so the file can never execute code.
    local k v
    while IFS='=' read -r k v; do
        v="${v#\'}"; v="${v%\'}"
        v="${v//\'\\\'\'/\'}"
        case "$k" in
            PANEL_URL|AUTH_MODE|PANEL_USER|PANEL_PASS|API_TOKEN|PANEL_RESOLVE|PANEL_INSECURE) printf -v "$k" '%s' "$v" ;;
        esac
    done < "$f"
    PANEL_URL="${PANEL_URL%/}"
    [ -n "$PANEL_URL" ] && [ -n "$AUTH_MODE" ]
}

# Write a config value safely single-quoted (handles ' in passwords).
xui_conf_line() { local v="${2//\'/\'\\\'\'}"; printf "%s='%s'\n" "$1" "$v"; }

xui_save_conf() {
    local f="${1:-$PANEL_CONF}"
    ( umask 077
      {
        xui_conf_line PANEL_URL "$PANEL_URL"
        xui_conf_line AUTH_MODE "$AUTH_MODE"
        xui_conf_line PANEL_USER "$PANEL_USER"
        xui_conf_line PANEL_PASS "$PANEL_PASS"
        xui_conf_line API_TOKEN "$API_TOKEN"
        xui_conf_line PANEL_RESOLVE "$PANEL_RESOLVE"
        xui_conf_line PANEL_INSECURE "$PANEL_INSECURE"
      } > "$f.tmp" && mv -f "$f.tmp" "$f" )
    chmod 600 "$f"
}

_xui_curl_opts() {
    XUI_CURL=(-sS --connect-timeout 10 --max-time "${XUI_TIMEOUT:-40}")
    [ -n "$PANEL_RESOLVE" ] && XUI_CURL+=(--resolve "$PANEL_RESOLVE")
    [ "$PANEL_INSECURE" = "1" ] && XUI_CURL+=(-k)
    return 0
}

_xui_errfile() { echo "$XUI_STATE_DIR/last.err"; }
# Last error text (survives $(...) subshells, which is how the helpers are normally called).
xui_err() { cat "$(_xui_errfile)" 2>/dev/null; }
_xui_wrap() {  # _xui_wrap <impl> args...
    local impl="$1"; shift
    XUI_LAST_ERR=""; mkdir -p "$XUI_STATE_DIR" 2>/dev/null
    : > "$(_xui_errfile)" 2>/dev/null
    "$impl" "$@"; local rc=$?
    [ $rc -ne 0 ] && [ -n "$XUI_LAST_ERR" ] && printf '%s' "$XUI_LAST_ERR" > "$(_xui_errfile)"
    return $rc
}
xui_login() { _xui_wrap _xui_login_impl "$@"; }
xui_api()   { _xui_wrap _xui_api_impl "$@"; }
xui_call()  { _xui_wrap _xui_call_impl "$@"; }

_xui_jar()  { echo "$XUI_STATE_DIR/session.jar"; }
_xui_csrf() { echo "$XUI_STATE_DIR/csrf.token"; }

# Fetch the session CSRF token (stored on disk so it survives $(...) subshells).
_xui_fetch_csrf() {
    local body tok
    body=$(curl "${XUI_CURL[@]}" -b "$(_xui_jar)" -c "$(_xui_jar)" \
        -H 'X-Requested-With: XMLHttpRequest' "$PANEL_URL/csrf-token" 2>&1) || { XUI_LAST_ERR="cannot reach panel: $body"; return 1; }
    tok=$(jq -r 'select(.success==true) | .obj // empty' <<<"$body" 2>/dev/null)
    [ -n "$tok" ] || { XUI_LAST_ERR="no CSRF token (wrong URL/base path?)"; return 1; }
    ( umask 077; printf '%s' "$tok" > "$(_xui_csrf)" )
}

# xui_login [twofactor]  -> 0 on success.  Token mode just validates the token.
_xui_login_impl() {
    _xui_curl_opts
    mkdir -p "$XUI_STATE_DIR"; chmod 700 "$XUI_STATE_DIR"
    if [ "$AUTH_MODE" = "token" ]; then
        [ -n "$API_TOKEN" ] || { XUI_LAST_ERR="no API token configured"; return 1; }
        local code
        code=$(curl "${XUI_CURL[@]}" -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $API_TOKEN" \
            -H 'X-Requested-With: XMLHttpRequest' "$PANEL_URL/panel/api/server/status" 2>/dev/null)
        case "$code" in
            200) return 0 ;;
            401) XUI_LAST_ERR="API token rejected (revoked/disabled?)" ;;
            000) XUI_LAST_ERR="cannot reach panel at $PANEL_URL" ;;
            *)   XUI_LAST_ERR="unexpected HTTP $code (check URL / base path)" ;;
        esac
        return 1
    fi
    rm -f "$(_xui_jar)" "$(_xui_csrf)"
    : > "$(_xui_jar)"; chmod 600 "$(_xui_jar)"
    _xui_fetch_csrf || return 1
    local resp
    resp=$(curl "${XUI_CURL[@]}" -b "$(_xui_jar)" -c "$(_xui_jar)" \
        -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $(cat "$(_xui_csrf)")" \
        --data-urlencode "username=$PANEL_USER" --data-urlencode "password=$PANEL_PASS" \
        --data-urlencode "twoFactorCode=${1:-}" "$PANEL_URL/login" 2>&1) || { XUI_LAST_ERR="login request failed: $resp"; return 1; }
    if [ "$(jq -r '.success' <<<"$resp" 2>/dev/null)" != "true" ]; then
        XUI_LAST_ERR="login rejected: $(jq -r '.msg // empty' <<<"$resp" 2>/dev/null)"
        [ -n "$XUI_LAST_ERR" ] || XUI_LAST_ERR="login rejected (unexpected response)"
        return 1
    fi
    _xui_fetch_csrf   # token is bound to the (new) session
}

# xui_api METHOD PATH [extra curl args...]
#   stdout: response body.  return: 0 ok | 1 API/HTTP error | 2 panel unreachable | 3 auth failed
#   Transparently re-logs in once on 401/403 (expired session) and retries.
_xui_api_impl() {
    local method="$1" path="$2"; shift 2
    _xui_curl_opts
    local attempt out code hdr=() rc
    for attempt in 1 2; do
        hdr=(-H 'X-Requested-With: XMLHttpRequest')
        if [ "$AUTH_MODE" = "token" ]; then
            hdr+=(-H "Authorization: Bearer $API_TOKEN")
        else
            [ -s "$(_xui_jar)" ] || { xui_login || return 3; }
            hdr+=(-b "$(_xui_jar)" -c "$(_xui_jar)" -H "X-CSRF-Token: $(cat "$(_xui_csrf)" 2>/dev/null)")
        fi
        out=$(mktemp)
        code=$(curl "${XUI_CURL[@]}" -X "$method" "${hdr[@]}" "$@" -o "$out" -w '%{http_code}' "$PANEL_URL$path" 2>/dev/null)
        rc=$?
        if [ $rc -ne 0 ] || [ "$code" = "000" ]; then
            rm -f "$out"; XUI_LAST_ERR="panel unreachable ($PANEL_URL)"; return 2
        fi
        if [ "$code" = "401" ] || [ "$code" = "403" ]; then
            rm -f "$out"
            if [ $attempt -eq 1 ]; then
                [ "$AUTH_MODE" = "token" ] && { XUI_LAST_ERR="API token rejected"; return 3; }
                xui_login || return 3      # session expired / CSRF stale -> reconnect
                continue
            fi
            XUI_LAST_ERR="authentication failed after re-login (HTTP $code)"; return 3
        fi
        cat "$out"; rm -f "$out"
        if [ "$code" != "200" ]; then XUI_LAST_ERR="HTTP $code on $method $path"; return 1; fi
        return 0
    done
    return 3
}

# Same as xui_api but additionally requires {"success":true}; sets XUI_LAST_ERR from .msg.
_xui_call_impl() {
    local body rc
    body=$(xui_api "$@"); rc=$?
    [ $rc -ne 0 ] && { printf '%s' "$body"; return $rc; }
    if [ "$(jq -r '.success' <<<"$body" 2>/dev/null)" != "true" ]; then
        XUI_LAST_ERR="$(jq -r '.msg // "request failed"' <<<"$body" 2>/dev/null)"
        printf '%s' "$body"; return 1
    fi
    printf '%s' "$body"
}

# ---------------------------------------------------------------- high level helpers

# Inbounds on THIS server only (nodeId == null), objects normalised so settings/streamSettings/
# sniffing are always objects (v3 returns objects; older builds returned JSON strings).
xui_inbounds() {
    local b; b=$(xui_call GET /panel/api/inbounds/list) || return $?
    jq -c '[.obj[]? | select(.nodeId == null)
        | .settings       |= (if type=="string" then (try fromjson catch {}) else . end)
        | .streamSettings |= (if type=="string" then (try fromjson catch {}) else . end)
        | .sniffing       |= (if type=="string" then (try fromjson catch {}) else . end)]' <<<"$b"
}

# xui_template_get <file> : writes the Xray template to <file>; sets XUI_TEST_URL.
xui_template_get() {
    local b inner
    b=$(xui_call POST /panel/api/xray/) || return $?
    inner=$(jq -r '.obj' <<<"$b")
    jq -e '.xraySetting.outbounds' <<<"$inner" >/dev/null 2>&1 || { XUI_LAST_ERR="unexpected xray template format"; return 1; }
    jq '.xraySetting' <<<"$inner" > "$1"
    XUI_TEST_URL=$(jq -r '.outboundTestUrl // empty' <<<"$inner")
    return 0
}

# xui_template_put <file> : saves the template (panel validates it and hot-applies it).
xui_template_put() {
    xui_call POST /panel/api/xray/update \
        --data-urlencode "xraySetting@$1" \
        --data-urlencode "outboundTestUrl=${XUI_TEST_URL:-https://www.google.com/generate_204}" >/dev/null
}

xui_xray_state() { xui_call GET /panel/api/server/status | jq -r '.obj.xray.state // "unknown"'; }
xui_xray_error() { xui_call GET /panel/api/server/status | jq -r '.obj.xray.errorMsg // ""'; }

xui_inbound_add() {      # <json-file> -> prints created inbound object (.obj)
    local b; b=$(xui_call POST /panel/api/inbounds/add -H 'Content-Type: application/json' --data-binary "@$1") || return $?
    jq -c '.obj' <<<"$b"
}
xui_inbound_enable() { xui_call POST "/panel/api/inbounds/setEnable/$1" -H 'Content-Type: application/json' -d "{\"enable\":$2}" >/dev/null; }
xui_inbound_del()    { xui_call POST "/panel/api/inbounds/del/$1" >/dev/null; }

xui_hosts_by_inbound() { xui_call GET "/panel/api/hosts/byInbound/$1" | jq -c '.obj // []'; }
xui_hosts_all()        { xui_call GET /panel/api/hosts/list | jq -c '.obj // []'; }
xui_host_add()         { xui_call POST /panel/api/hosts/add -H 'Content-Type: application/json' --data-binary "@$1" >/dev/null; }

xui_onlines()          { xui_call POST /panel/api/clients/onlines | jq -c '.obj // []'; }
xui_outbound_traffic() { xui_call GET /panel/api/xray/getOutboundsTraffic | jq -c '.obj // []'; }

# ---------------------------------------------------------------- local panel auto-detection

xui_find_bin() {
    local d
    for d in "${XUI_MAIN_FOLDER:-/usr/local/x-ui}/x-ui" /usr/local/x-ui/x-ui; do
        [ -x "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

# Sets: DET_URL DET_RESOLVE DET_NOTE   (read-only: only uses `x-ui setting -show/-getCert/-getListen`)
xui_detect_local() {
    DET_URL="" DET_RESOLVE="" DET_NOTE=""
    local bin out port base cert listen scheme host cn
    bin=$(xui_find_bin) || { DET_NOTE="3x-ui binary not found"; return 1; }
    out=$("$bin" setting -show 2>/dev/null)
    port=$(sed -n 's/^port: *//p' <<<"$out" | head -1)
    base=$(sed -n 's/^webBasePath: *//p' <<<"$out" | head -1)
    [ -n "$port" ] || { DET_NOTE="could not read panel port"; return 1; }
    base="/${base#/}"; base="${base%/}"
    cert=$("$bin" setting -getCert 2>/dev/null | sed -n 's/^cert: *//p' | head -1)
    listen=$("$bin" setting -getListen 2>/dev/null | sed -n 's/^listenIP: *//p' | head -1)
    host="127.0.0.1"
    case "$listen" in ""|0.0.0.0|::|"[::]") ;; *) host="$listen" ;; esac
    if [ -n "$cert" ] && [ -r "$cert" ]; then
        scheme=https
        cn=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^, ]*' | head -1 | cut -d: -f2)
        [ -n "$cn" ] || cn=$(openssl x509 -in "$cert" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p' | head -1)
        if [ -n "$cn" ] && [[ "$cn" != \** ]]; then
            DET_URL="https://$cn:$port$base"; DET_RESOLVE="$cn:$port:$host"
        else
            DET_URL="https://$host:$port$base"; DET_NOTE="certificate has no usable domain name; TLS verification may need 'insecure'"
        fi
    else
        DET_URL="http://$host:$port$base"
    fi
    return 0
}
