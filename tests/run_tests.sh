#!/usr/bin/env bash
###############################################################################
# Verification suite for xemireverse
#
# The suite sources the main script, which only defines functions when it is
# not executed directly, then redirects every path into a sandbox. No system
# file is touched and root is not required.
#
# Usage
#   bash tests/run_tests.sh
#
# The nginx -t case runs only when an nginx binary is present, otherwise it is
# reported as SKIP.
###############################################################################

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$TESTS_DIR")"

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# shellcheck source=../xemireverse disable=SC1091
source "$REPO_ROOT/xemireverse"

# The script sets -Eeuo pipefail and a restrictive IFS, the harness needs
# neither, it checks every result explicitly
set +eE +u +o pipefail
IFS=$' \t\n'

# Redirect the script globals into the sandbox. They look unused here because
# the consumer is the sourced script, not this file.
# shellcheck disable=SC2034
NGINX_CONF_DIR="$SANDBOX/conf.d"
DB_FILE="$SANDBOX/reverse-manager.db"
CERT_DIR="$SANDBOX/certs"
BACKUP_DIR="$SANDBOX/backups"
# shellcheck disable=SC2034
LOG_FILE="$SANDBOX/reverse-manager.log"
mkdir -p "$NGINX_CONF_DIR" "$CERT_DIR" "$BACKUP_DIR"
: >"$DB_FILE"

PASS=0
FAIL=0
SKIP=0
CURRENT_CASE=""

case_start() {
  CURRENT_CASE="$1"
  printf '\n=== %s ===\n' "$CURRENT_CASE"
}

ok() {
  PASS=$((PASS + 1))
  printf '  [PASS] %s\n' "$1"
}

ko() {
  FAIL=$((FAIL + 1))
  printf '  [FAIL] %s\n' "$1"
}

skip() {
  SKIP=$((SKIP + 1))
  printf '  [SKIP] %s\n' "$1"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    ok "$label"
  else
    ko "$label, expected to find: $needle"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    ko "$label, did not expect: $needle"
  else
    ok "$label"
  fi
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label"
  else
    ko "$label, expected [$expected] got [$actual]"
  fi
}

assert_count() {
  local haystack="$1" needle="$2" expected="$3" label="$4"
  local n
  n="$(printf '%s\n' "$haystack" | grep -cF -- "$needle")"
  if [[ "$n" == "$expected" ]]; then
    ok "$label"
  else
    ko "$label, expected $expected occurrences of [$needle] got $n"
  fi
}

###############################################################################
# Structural checks that do not need an nginx binary
###############################################################################
assert_braces_balanced() {
  local conf="$1" label="$2"
  local opens closes
  opens="$(printf '%s' "$conf" | tr -cd '{' | wc -c)"
  closes="$(printf '%s' "$conf" | tr -cd '}' | wc -c)"
  if [[ "$opens" -eq "$closes" ]] && [[ "$opens" -gt 0 ]]; then
    ok "$label"
  else
    ko "$label, $opens open braces against $closes closing braces"
  fi
}

assert_no_duplicate_directives() {
  # Nginx refuses a repeated single value directive inside the same block, for
  # example two proxy_read_timeout in one location. proxy_set_header is the
  # legitimate exception.
  local conf="$1" label="$2"
  local report
  report="$(printf '%s\n' "$conf" | awk '
    # Sibling blocks at the same depth must not share state, so every key
    # recorded for a depth is dropped when a block at that depth opens or closes
    function clear_depth(d,   k) {
      for (k in seen) {
        if (index(k, d "|") == 1) delete seen[k]
      }
    }
    /\{[[:space:]]*$/ { depth++; clear_depth(depth); next }
    /^[[:space:]]*\}/ { clear_depth(depth); depth--; next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "" || line ~ /^#/) next
      name = line
      sub(/[[:space:]].*$/, "", name)
      sub(/;$/, "", name)
      if (name == "proxy_set_header") next
      key = depth "|" name
      if (key in seen) { print "duplicate " name " at depth " depth }
      seen[key] = 1
    }
  ')"
  if [[ -z "$report" ]]; then
    ok "$label"
  else
    ko "$label, $report"
  fi
}

assert_every_directive_terminated() {
  local conf="$1" label="$2"
  local bad
  bad="$(printf '%s\n' "$conf" \
    | grep -vE '^[[:space:]]*(#|$)' \
    | grep -vE '[;{}][[:space:]]*$' || true)"
  if [[ -z "$bad" ]]; then
    ok "$label"
  else
    ko "$label, unterminated lines: $(printf '%s' "$bad" | tr '\n' '|')"
  fi
}

###############################################################################
# 1. Plain HTTP domain, websocket=no
###############################################################################
case_start "HTTP domain without the WebSocket capability"
conf_http="$(render_nginx_conf "plain.example.com" "http://127.0.0.1:8000" "no" "no" "no" "/ws/" "django")"

assert_contains "$conf_http" "location / {" "root location is generated"
assert_contains "$conf_http" 'proxy_set_header Connection "";' "keeps the plain HTTP Connection header"
assert_contains "$conf_http" "proxy_http_version 1.1;" "uses HTTP/1.1 to the backend"
assert_not_contains "$conf_http" "Upgrade" "no Upgrade header anywhere"
assert_not_contains "$conf_http" "location /ws/" "no WebSocket location"
assert_contains "$conf_http" "## WebSocket, no" "header documents the capability"
assert_braces_balanced "$conf_http" "braces balanced"
assert_no_duplicate_directives "$conf_http" "no duplicate directives inside a block"
assert_every_directive_terminated "$conf_http" "every directive terminated"

###############################################################################
# 2. WebSocket domain on the default path
###############################################################################
case_start "WebSocket domain on /ws/"
conf_ws="$(render_nginx_conf "ws.example.com" "http://127.0.0.1:8000" "no" "no" "yes" "/ws/" "django")"

assert_contains "$conf_ws" "location / {" "root location still generated"
assert_contains "$conf_ws" 'proxy_set_header Connection "";' "root location keeps Connection empty"
assert_contains "$conf_ws" "location /ws/ {" "WebSocket location generated"
assert_contains "$conf_ws" 'proxy_set_header Upgrade           $http_upgrade;' "forwards the Upgrade header"
assert_contains "$conf_ws" 'proxy_set_header Connection        "upgrade";' "forwards Connection upgrade"
assert_count "$conf_ws" "proxy_http_version 1.1;" 2 "HTTP/1.1 in both locations"
assert_count "$conf_ws" 'proxy_set_header Host              $host;' 2 "proxy headers preserved in both locations"
assert_count "$conf_ws" 'proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;' 2 "X-Forwarded-For preserved in both locations"
assert_contains "$conf_ws" "## WebSocket, yes, path /ws/" "header documents the capability"
assert_braces_balanced "$conf_ws" "braces balanced"
assert_no_duplicate_directives "$conf_ws" "no duplicate directives inside a block"
assert_every_directive_terminated "$conf_ws" "every directive terminated"

# The upgrade headers must not leak into the root location
root_only="$(printf '%s\n' "$conf_ws" | awk '/location \/ \{/{f=1} f&&/^    \}/{print;f=0} f')"
assert_not_contains "$root_only" "Upgrade" "root location does not carry Upgrade"

###############################################################################
# 3. Custom WebSocket path
###############################################################################
case_start "Custom WebSocket path"
conf_socket="$(render_nginx_conf "s.example.com" "http://127.0.0.1:8000" "no" "no" "yes" "/socket/" "generic")"
assert_contains "$conf_socket" "location /socket/ {" "location /socket/ generated"
assert_not_contains "$conf_socket" "location /ws/" "default path not emitted"

conf_chat="$(render_nginx_conf "c.example.com" "http://127.0.0.1:8000" "no" "no" "yes" "/ws/chat/" "generic")"
assert_contains "$conf_chat" "location /ws/chat/ {" "nested path generated"

###############################################################################
# 4. SSL and HTTPS backend combined with WebSocket
###############################################################################
case_start "SSL vhost with an HTTPS backend and WebSocket"
conf_ssl="$(render_nginx_conf "secure.example.com" "https://10.0.0.20:8443" "yes" "yes" "yes" "/ws/" "django")"

assert_contains "$conf_ssl" "return 301 https://\$host\$request_uri;" "port 80 still redirects"
assert_contains "$conf_ssl" "listen 443 ssl http2;" "TLS server block present"
assert_contains "$conf_ssl" "server_name secure.example.com *.secure.example.com;" "wildcard server_name preserved"
assert_count "$conf_ssl" "proxy_ssl_server_name on;" 2 "backend TLS applied to both locations"
assert_count "$conf_ssl" "proxy_ssl_verify off;" 2 "backend TLS verify setting applied to both locations"
assert_count "$conf_ssl" "location /ws/ {" 1 "WebSocket location only inside the TLS server"
assert_braces_balanced "$conf_ssl" "braces balanced"
assert_no_duplicate_directives "$conf_ssl" "no duplicate directives inside a block"
assert_every_directive_terminated "$conf_ssl" "every directive terminated"

###############################################################################
# 5. WebSocket path validation
###############################################################################
case_start "WebSocket path validation"

for good in "/ws/" "/socket/" "/ws/chat/" "/realtime/v1/"; do
  if out="$(normalize_websocket_path "$good")"; then
    assert_eq "$out" "$good" "accepts $good"
  else
    ko "accepts $good, was rejected"
  fi
done

# Values that must be normalized rather than rejected
assert_eq "$(normalize_websocket_path "/ws")" "/ws/" "adds the trailing slash to /ws"
assert_eq "$(normalize_websocket_path "  /ws/  ")" "/ws/" "trims surrounding whitespace"

while IFS= read -r bad; do
  [[ -z "$bad" ]] && continue
  if normalize_websocket_path "$bad" >/dev/null 2>&1; then
    ko "rejects [$bad], it was accepted"
  else
    ok "rejects [$bad]"
  fi
done <<'BAD_PATHS'
ws
http://example.com
/ws/ {
/ws/;
/ws/";
/ws/$host
/ws/ proxy_pass http://evil;
../ws/
/ws//chat/
/ws/../../etc/
/
BAD_PATHS

# A newline bearing value has to be rejected too
if normalize_websocket_path "$(printf '/ws/\nlocation /x/ {')" >/dev/null 2>&1; then
  ko "rejects a value containing a newline, it was accepted"
else
  ok "rejects a value containing a newline"
fi

# An empty answer is rejected so the caller re-prompts
if normalize_websocket_path "" >/dev/null 2>&1; then
  ko "rejects an empty path, it was accepted"
else
  ok "rejects an empty path"
fi

###############################################################################
# 6. Legacy database rows
###############################################################################
case_start "Legacy database compatibility"

# 3.5 shape, no mode and no capability keys
parse_entry "legacy35.example.com;http://127.0.0.1:8080;wildcard=no;ssl=yes"
assert_eq "$ENTRY_DOMAIN" "legacy35.example.com" "3.5 row, domain"
assert_eq "$ENTRY_BACKEND_URL" "http://127.0.0.1:8080" "3.5 row, backend"
assert_eq "$ENTRY_WILDCARD" "no" "3.5 row, wildcard"
assert_eq "$ENTRY_SSL" "yes" "3.5 row, ssl"
assert_eq "$ENTRY_MODE" "generated" "3.5 row, mode defaults to generated"
assert_eq "$ENTRY_PROFILE" "generic" "3.5 row, profile defaults to generic"
assert_eq "$ENTRY_WEBSOCKET" "no" "3.5 row, websocket defaults to no"
assert_eq "$ENTRY_WEBSOCKET_PATH" "/ws/" "3.5 row, websocket path defaults to /ws/"

# 3.6 shape, mode present, no capability keys
parse_entry "legacy36.example.com;https://10.0.0.20:8443;wildcard=yes;ssl=yes;mode=manual"
assert_eq "$ENTRY_MODE" "manual" "3.6 row, manual mode preserved"
assert_eq "$ENTRY_WILDCARD" "yes" "3.6 row, wildcard"
assert_eq "$ENTRY_WEBSOCKET" "no" "3.6 row, websocket defaults to no"

# A legacy row must render exactly what it rendered before
conf_legacy="$(render_nginx_conf "legacy35.example.com" "http://127.0.0.1:8080" \
  "$ENTRY_WILDCARD" "no" "$ENTRY_WEBSOCKET" "$ENTRY_WEBSOCKET_PATH" "$ENTRY_PROFILE")"
assert_not_contains "$conf_legacy" "Upgrade" "legacy row renders without Upgrade"
assert_contains "$conf_legacy" 'proxy_set_header Connection "";' "legacy row keeps the plain HTTP behaviour"

# A row carrying a corrupted path falls back instead of emitting it
parse_entry "broken.example.com;http://127.0.0.1:8000;wildcard=no;ssl=no;mode=generated;profile=django;websocket=yes;websocket_path=oops"
assert_eq "$ENTRY_WEBSOCKET_PATH" "/ws/" "a corrupted stored path falls back to the default"

# A legacy file has to survive a full read, write, read cycle untouched in shape
: >"$DB_FILE"
printf '%s\n' "old1.example.com;http://127.0.0.1:8080;wildcard=no;ssl=yes" >>"$DB_FILE"
printf '%s\n' "old2.example.com;http://127.0.0.1:9000;wildcard=no;ssl=no;mode=manual" >>"$DB_FILE"
db_save_entry "new.example.com" "http://127.0.0.1:8000" "no" "yes" "generated" "django" "yes" "/ws/"

assert_eq "$(grep -c . "$DB_FILE")" "3" "new row appended without dropping legacy rows"
assert_contains "$(cat "$DB_FILE")" "old1.example.com;http://127.0.0.1:8080;wildcard=no;ssl=yes" "legacy 3.5 row untouched"
assert_contains "$(cat "$DB_FILE")" "old2.example.com;http://127.0.0.1:9000;wildcard=no;ssl=no;mode=manual" "legacy 3.6 row untouched"
assert_contains "$(cat "$DB_FILE")" "new.example.com;http://127.0.0.1:8000;wildcard=no;ssl=yes;mode=generated;profile=django;websocket=yes;websocket_path=/ws/" "new row uses the extended shape"

# Reading the untouched legacy row back still yields the safe defaults
parse_entry "$(db_get_entry_exact "old2.example.com")"
assert_eq "$ENTRY_MODE" "manual" "legacy row still parses after the file was rewritten"
assert_eq "$ENTRY_WEBSOCKET" "no" "legacy row still defaults to websocket no"

###############################################################################
# 7. Enable and disable through the stored entry
###############################################################################
case_start "Enable then disable the capability on an existing domain"

: >"$DB_FILE"
db_save_entry "edit.example.com" "http://127.0.0.1:8000" "no" "no" "generated" "django" "no" "/ws/"
parse_entry "$(db_get_entry_exact "edit.example.com")"
assert_eq "$ENTRY_WEBSOCKET" "no" "starts without the capability"

generate_nginx_conf "edit.example.com" "$ENTRY_BACKEND_URL" "$ENTRY_WILDCARD" "$ENTRY_SSL" \
  "$ENTRY_WEBSOCKET" "$ENTRY_WEBSOCKET_PATH" "$ENTRY_PROFILE" >/dev/null
assert_not_contains "$(cat "$NGINX_CONF_DIR/edit.example.com.conf")" "location /ws/" "generated file has no WebSocket location"

# Enable, exactly what edit option 4 does
db_save_entry "edit.example.com" "$ENTRY_BACKEND_URL" "$ENTRY_WILDCARD" "$ENTRY_SSL" "generated" \
  "$ENTRY_PROFILE" "yes" "/ws/"
parse_entry "$(db_get_entry_exact "edit.example.com")"
assert_eq "$ENTRY_WEBSOCKET" "yes" "capability persisted as enabled"
assert_eq "$(grep -c . "$DB_FILE")" "1" "the row was updated, not duplicated"

generate_nginx_conf "edit.example.com" "$ENTRY_BACKEND_URL" "$ENTRY_WILDCARD" "$ENTRY_SSL" \
  "$ENTRY_WEBSOCKET" "$ENTRY_WEBSOCKET_PATH" "$ENTRY_PROFILE" >/dev/null
conf_after_enable="$(cat "$NGINX_CONF_DIR/edit.example.com.conf")"
assert_contains "$conf_after_enable" "location /ws/ {" "regenerated file gained the WebSocket location"
assert_contains "$conf_after_enable" 'proxy_set_header Upgrade           $http_upgrade;' "regenerated file forwards Upgrade"

# Change the path
db_save_entry "edit.example.com" "$ENTRY_BACKEND_URL" "$ENTRY_WILDCARD" "$ENTRY_SSL" "generated" \
  "$ENTRY_PROFILE" "yes" "/socket/"
parse_entry "$(db_get_entry_exact "edit.example.com")"
generate_nginx_conf "edit.example.com" "$ENTRY_BACKEND_URL" "$ENTRY_WILDCARD" "$ENTRY_SSL" \
  "$ENTRY_WEBSOCKET" "$ENTRY_WEBSOCKET_PATH" "$ENTRY_PROFILE" >/dev/null
conf_after_path="$(cat "$NGINX_CONF_DIR/edit.example.com.conf")"
assert_contains "$conf_after_path" "location /socket/ {" "path change applied"
assert_not_contains "$conf_after_path" "location /ws/" "previous path removed"

# Disable again
db_save_entry "edit.example.com" "$ENTRY_BACKEND_URL" "$ENTRY_WILDCARD" "$ENTRY_SSL" "generated" \
  "$ENTRY_PROFILE" "no" "$ENTRY_WEBSOCKET_PATH"
parse_entry "$(db_get_entry_exact "edit.example.com")"
assert_eq "$ENTRY_WEBSOCKET" "no" "capability persisted as disabled"
assert_eq "$ENTRY_WEBSOCKET_PATH" "/socket/" "the path is remembered for a later re-enable"

generate_nginx_conf "edit.example.com" "$ENTRY_BACKEND_URL" "$ENTRY_WILDCARD" "$ENTRY_SSL" \
  "$ENTRY_WEBSOCKET" "$ENTRY_WEBSOCKET_PATH" "$ENTRY_PROFILE" >/dev/null
conf_after_disable="$(cat "$NGINX_CONF_DIR/edit.example.com.conf")"
assert_not_contains "$conf_after_disable" "location /socket/" "WebSocket location removed"
assert_not_contains "$conf_after_disable" "Upgrade" "no Upgrade header left behind"
assert_contains "$conf_after_disable" "location / {" "root location intact"

###############################################################################
# 8. Interactive create and edit flows
#
# Drives the real TUI functions with scripted answers. Screen clearing, pauses
# and the Nginx calls are stubbed, everything else is the production path.
###############################################################################
case_start "Interactive create and edit flows"

clear_screen() { :; }
sleep_soft() { :; }
pause() { :; }
# Without a local Nginx, safe_reload_nginx would roll the change back, which is
# correct behaviour but would hide what the flow produced
nginx_test_quiet() { return 0; }
nginx_test_verbose() { return 0; }
reload_nginx_portable() { return 0; }

: >"$DB_FILE"
FLOW_LOG="$SANDBOX/flow.log"

# Create, Django profile, no wildcard, no SSL, WebSockets on the default path
create_domain >"$FLOW_LOG" 2>&1 <<'ANSWERS'
flow.example.com
2
http://127.0.0.1:8000
n
n
y

ANSWERS

flow_row="$(db_get_entry_exact "flow.example.com")"
assert_contains "$flow_row" "profile=django" "create persists the chosen profile"
assert_contains "$flow_row" "websocket=yes" "create persists the capability"
assert_contains "$flow_row" "websocket_path=/ws/" "create persists the default path"

flow_conf="$NGINX_CONF_DIR/flow.example.com.conf"
if [[ -f "$flow_conf" ]]; then
  ok "create wrote the vhost file"
  assert_contains "$(cat "$flow_conf")" "location /ws/ {" "created vhost carries the WebSocket location"
  assert_contains "$(cat "$flow_conf")" "## Profile, django" "created vhost records the profile"
else
  ko "create wrote the vhost file"
fi

# Edit, select the only domain, change the WebSocket path, save, back
edit_domain >>"$FLOW_LOG" 2>&1 <<'ANSWERS'
1
5
/socket/
7
0
ANSWERS

flow_row="$(db_get_entry_exact "flow.example.com")"
assert_contains "$flow_row" "websocket_path=/socket/" "edit persists the new path"
assert_contains "$(cat "$flow_conf")" "location /socket/ {" "edit regenerated the vhost"
assert_not_contains "$(cat "$flow_conf")" "location /ws/" "old path removed from the vhost"

# Edit again, disable the capability, save, back
edit_domain >>"$FLOW_LOG" 2>&1 <<'ANSWERS'
1
4
7
0
ANSWERS

flow_row="$(db_get_entry_exact "flow.example.com")"
assert_contains "$flow_row" "websocket=no" "edit persists the disabled capability"
assert_contains "$flow_row" "websocket_path=/socket/" "the path survives for a later re-enable"
assert_not_contains "$(cat "$flow_conf")" "Upgrade" "disabling removed the upgrade headers"
assert_contains "$(cat "$flow_conf")" "location / {" "root location survived the round trip"

# A rejected path must not be persisted or rendered
edit_domain >>"$FLOW_LOG" 2>&1 <<'ANSWERS'
1
4
/ws/ { deny all; }
/danger;
/safe/
7
0
ANSWERS

flow_row="$(db_get_entry_exact "flow.example.com")"
assert_contains "$flow_row" "websocket_path=/safe/" "the prompt re-asked until the path was valid"
assert_not_contains "$(cat "$flow_conf")" "deny all" "the rejected path never reached the config"
assert_contains "$(cat "$flow_conf")" "location /safe/ {" "the accepted path was rendered"

# The log records the capability events
assert_contains "$(cat "$LOG_FILE")" "WebSocket capability enabled for flow.example.com path=/ws/" "create logged the capability"
assert_contains "$(cat "$LOG_FILE")" "WebSocket capability disabled for flow.example.com" "edit logged the disable"
assert_contains "$(cat "$LOG_FILE")" "WebSocket path changed for flow.example.com" "edit logged the path change"

###############################################################################
# 9. Existing safety guarantees still hold on generated files
###############################################################################
case_start "Safety guarantees on the generated file"

generate_nginx_conf "safety.example.com" "https://10.0.0.20:8443" "no" "no" "yes" "/ws/" "django" >/dev/null
safety_conf="$NGINX_CONF_DIR/safety.example.com.conf"

if conf_must_not_contain_cr "$safety_conf"; then
  ok "no CR characters in the generated file"
else
  ko "no CR characters in the generated file"
fi

if conf_must_not_contain_forbidden_tokens "$safety_conf"; then
  ok "no forbidden placeholder tokens"
else
  ko "no forbidden placeholder tokens"
fi

if validate_conf_for_domain "$safety_conf"; then
  ok "passes validate_conf_for_domain"
else
  ko "passes validate_conf_for_domain"
fi

if LC_ALL=C grep -Pq '[^\x09\x0A\x0D\x20-\x7E]' "$safety_conf" 2>/dev/null; then
  ko "no non printable characters"
else
  ok "no non printable characters"
fi

# The renderer must never be reachable with an unvalidated path
if (generate_nginx_conf "inject.example.com" "http://127.0.0.1:8000" "no" "no" "yes" '/ws/ { deny all; }' "generic") >/dev/null 2>&1; then
  ko "generate_nginx_conf rejects an unsafe path"
else
  ok "generate_nginx_conf rejects an unsafe path"
fi
if [[ -f "$NGINX_CONF_DIR/inject.example.com.conf" ]]; then
  ko "no file is written for a rejected path"
else
  ok "no file is written for a rejected path"
fi

# Manual mode must never be overwritten by a save that changed nothing
: >"$DB_FILE"
db_save_entry "manual.example.com" "http://127.0.0.1:8000" "no" "no" "manual" "generic" "yes" "/ws/"
manual_conf="$NGINX_CONF_DIR/manual.example.com.conf"
cat >"$manual_conf" <<'MANUALCONF'
server {
    listen 80;
    server_name manual.example.com;

    # hand written by the operator
    location / {
        proxy_pass http://127.0.0.1:8000;
    }
}
MANUALCONF

parse_entry "$(db_get_entry_exact "manual.example.com")"
save_domain_edits "$SANDBOX/backups" "$manual_conf" >/dev/null 2>&1

assert_contains "$(cat "$manual_conf")" "# hand written by the operator" "manual config is not regenerated on save"
assert_not_contains "$(cat "$manual_conf")" "Auto generated by" "manual config keeps its own content"
assert_contains "$(db_get_entry_exact "manual.example.com")" "mode=manual" "manual mode is preserved in the registry"
assert_contains "$(db_get_entry_exact "manual.example.com")" "websocket=yes" "capability fields survive a manual mode save"

###############################################################################
# 10. Backward compatible renderer signature
###############################################################################
case_start "3.6 renderer signature still works"
conf_old_sig="$(render_nginx_conf "old.example.com" "http://127.0.0.1:8000" "no" "no")"
assert_contains "$conf_old_sig" "location / {" "renders with four arguments"
assert_not_contains "$conf_old_sig" "location /ws/" "four argument call stays HTTP only"

###############################################################################
# 11. Shell syntax and nginx validation
###############################################################################
case_start "Shell and Nginx validation"

if bash -n "$REPO_ROOT/xemireverse"; then
  ok "bash -n on xemireverse"
else
  ko "bash -n on xemireverse"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$REPO_ROOT/xemireverse"; then
    ok "shellcheck clean at warning level"
  else
    ko "shellcheck reported findings"
  fi
else
  skip "shellcheck not installed"
fi

if command -v nginx >/dev/null 2>&1; then
  # Build a minimal but complete nginx tree around the generated vhosts
  NGX_ROOT="$SANDBOX/nginx"
  mkdir -p "$NGX_ROOT/conf.d" "$NGX_ROOT/logs" "$NGX_ROOT/temp"

  render_nginx_conf "t1.example.com" "http://127.0.0.1:8000" "no" "no" "no" "/ws/" "generic" \
    >"$NGX_ROOT/conf.d/t1.conf"
  render_nginx_conf "t2.example.com" "http://127.0.0.1:8000" "no" "yes" "yes" "/ws/" "django" \
    >"$NGX_ROOT/conf.d/t2.conf"
  render_nginx_conf "t3.example.com" "https://10.0.0.20:8443" "yes" "no" "yes" "/ws/chat/" "flask-fastapi" \
    >"$NGX_ROOT/conf.d/t3.conf"

  # t2 declares TLS, so it needs certificate files to exist
  CERT_DIR_FOR_TEST="$CERT_DIR"
  if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "$CERT_DIR_FOR_TEST/t2.example.com.key" \
      -out "$CERT_DIR_FOR_TEST/t2.example.com.pem" \
      -days 1 -subj "/CN=t2.example.com" >/dev/null 2>&1
  fi

  cat >"$NGX_ROOT/nginx.conf" <<NGXCONF
events { worker_connections 64; }
http {
    access_log $NGX_ROOT/logs/access.log;
    client_body_temp_path $NGX_ROOT/temp;
    proxy_temp_path $NGX_ROOT/temp/proxy;
    fastcgi_temp_path $NGX_ROOT/temp/fastcgi;
    uwsgi_temp_path $NGX_ROOT/temp/uwsgi;
    scgi_temp_path $NGX_ROOT/temp/scgi;
    include $NGX_ROOT/conf.d/*.conf;
}
NGXCONF

  if nginx_out="$(nginx -t -c "$NGX_ROOT/nginx.conf" -p "$NGX_ROOT" -e "$NGX_ROOT/logs/error.log" 2>&1)"; then
    ok "nginx -t accepts the generated configurations"
    printf '         %s\n' "$nginx_out"
  else
    ko "nginx -t rejected the generated configurations: $nginx_out"
  fi
else
  skip "nginx binary not available, nginx -t not executed"
fi

###############################################################################
# Summary
###############################################################################
printf '\n-----------------------------------------\n'
printf 'passed %d, failed %d, skipped %d\n' "$PASS" "$FAIL" "$SKIP"

if (( FAIL > 0 )); then
  exit 1
fi
exit 0
