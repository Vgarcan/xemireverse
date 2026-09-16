# `xemireverse` — Reverse Manager for Nginx

Interactive CLI tool to safely manage Nginx reverse proxy virtual hosts for multiple backends, including WordPress, Django, Flask, FastAPI, static sites, control panels and internal services.

```text
Internet → Cloudflare → Reverse Nginx (xemireverse) → Backend
````

## Table of Contents

* [Overview](#overview)
* [Features](#features)
* [Architecture](#architecture)
* [Requirements](#requirements)
* [Installation](#installation)
* [Usage](#usage)
* [Profiles and Capabilities](#profiles-and-capabilities)
* [WebSocket Reverse Proxy](#websocket-reverse-proxy)
* [Database Format](#database-format)
* [Files and Directories](#files-and-directories)
* [SSL Certificates](#ssl-certificates)
* [Safety Features](#safety-features)
* [Menu Options](#menu-options)
* [Examples](#examples)
* [Tests](#tests)
* [Troubleshooting](#troubleshooting)

## Overview

`xemireverse` is a Bash-based terminal tool that manages Nginx reverse proxy configurations from an interactive menu.

It creates and maintains domain mappings, generates Nginx vhost files, validates configuration before reload, creates backups, and rolls back automatically if something fails.

## Features

* Create, edit, list, view and delete reverse proxy domains
* Generate Nginx configs under `/etc/nginx/conf.d`
* Capability aware generation, the config matches what the application needs
* WebSocket reverse proxy support on a configurable path
* Support HTTP and HTTPS backends
* Optional SSL termination on the reverse proxy
* Wildcard domain support
* Manual config edit mode
* Safe Nginx reload with backup and rollback
* Audit and sanitize existing `.conf` files
* Remove CRLF and non printable characters
* Block unresolved placeholder tokens
* Delete associated certs when deleting a domain
* Log operations to `/var/log/reverse-manager.log`

## Architecture

Recommended topology:

```text
Client → Cloudflare → Reverse Nginx → Backend service
```

The reverse proxy is the public entry point. Backends can be local services, LAN services, CWP sites, Django apps, Flask apps, APIs, or admin panels.

## Requirements

Required:

```bash
bash
nginx
openssl
root privileges
```

Optional:

```bash
systemctl
service
nano
vi
less
```

## Installation

Save the script as:

```bash
/usr/local/bin/xemireverse
```

Make it executable:

```bash
chmod +x /usr/local/bin/xemireverse
```

Run it:

```bash
sudo xemireverse
```

## Usage

Start the tool:

```bash
sudo xemireverse
```

Main menu:

```text
1  Create domain
2  List domains
3  View domain conf
4  Edit domain
5  Delete domain
6  Test Nginx
7  Safe reload Nginx
8  Audit conf.d
9  Sanitize conf.d
10 Environment check
0  Exit
```

## Profiles and Capabilities

`xemireverse` separates two different questions.

**Profile** describes the kind of application:

```text
WordPress / PHP
Django
Flask / FastAPI
Static site
Generic service
```

The profile is stored with the domain. It drives the guidance shown while
creating a domain, the backend examples, and the wording of the capability
questions. It never enables anything by itself.

**Capabilities** describe the proxy behaviour the application actually needs.
They are always answered explicitly by the operator:

```text
WebSocket / realtime support: yes
WebSocket path: /ws/
```

A Django project is not assumed to need WebSockets, and neither is FastAPI.
Many of them are plain request and response applications.

The capability model is the extension point for future proxy behaviour such as
SSE streaming, large uploads, custom buffering or custom timeouts. None of that
is implemented yet.

## WebSocket Reverse Proxy

### Why a normal reverse proxy config is not enough

A plain HTTP location ends with:

```nginx
proxy_http_version 1.1;
proxy_set_header Connection "";
```

`Upgrade` and `Connection` are hop by hop headers. Nginx does not pass them
upstream on its own, and the line above deliberately clears `Connection` so
keepalive to the backend works.

The result is that a WebSocket handshake sent by the browser arrives at the
backend as an ordinary HTTP GET. An ASGI server such as Daphne or Uvicorn has
no WebSocket route for a plain HTTP request, so the request usually ends in
`404` and the browser never gets its realtime events.

Enabling the WebSocket capability adds a dedicated location that forwards the
handshake:

```nginx
location /ws/ {
    proxy_pass http://127.0.0.1:8000;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host  $host;

    proxy_http_version 1.1;
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        "upgrade";
}
```

The rest of the site keeps the plain HTTP behaviour. The upgrade headers are
not applied globally, only to the declared path.

### Redis is not a reverse proxy concern

The problem above was originally found on a Django Channels project that uses
Redis as channel layer, but Redis is not what decides this configuration.

Nginx never talks to Redis here. The traffic path is:

```text
Browser → Cloudflare → Reverse Nginx → Daphne → Django Channels → Redis
```

Nginx only has to preserve the upgrade between itself and the application
server. An application can use Redis for cache, sessions, Celery, queues,
pub/sub or rate limiting and never open a single WebSocket.

For that reason `xemireverse` asks whether the application uses WebSockets, not
which services run behind it. It does not install, inspect or configure Redis.

### Why `Connection "upgrade"` instead of a `map`

The common Nginx pattern is:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

That map exists so a single shared location can serve upgrade and non upgrade
traffic through the same `Connection` header. It is only valid in the `http`
context.

`xemireverse` generates one file per domain in `/etc/nginx/conf.d`, which is
included from `http`, so a `map` would be syntactically legal there. It is
still avoided at this stage:

* one map per domain file means a duplicated `$connection_upgrade` variable as
  soon as two domains enable WebSockets, and Nginx refuses to start
* a single shared file would collide with a `connection_upgrade` map already
  declared by a distribution package, a control panel, or the administrator,
  and that failure takes down every vhost, not only the new one
* a dedicated WebSocket location does not need the conditional form, the
  constant is correct for every request that belongs on that path

A `map` becomes worth revisiting if WebSocket support ever has to live inside
the shared `location /` instead of a dedicated path.

### Django with Daphne and Channels

```text
Domain: app.example.com
Profile: Django
Backend: http://127.0.0.1:8000
SSL: yes
WebSocket: yes
WebSocket path: /ws/
```

Matching Django routing:

```python
# routing.py
websocket_urlpatterns = [
    re_path(r"^ws/notifications/$", NotificationConsumer.as_asgi()),
]
```

The browser connects to `wss://app.example.com/ws/notifications/`. Nginx
terminates TLS, matches the `/ws/` prefix location and upgrades the connection
to Daphne on port 8000.

### FastAPI

```text
Domain: api.example.com
Profile: Flask / FastAPI
Backend: http://127.0.0.1:5000
SSL: yes
WebSocket: yes
WebSocket path: /ws/
```

```python
@app.websocket("/ws/feed")
async def feed(websocket: WebSocket):
    await websocket.accept()
```

### wss and HTTPS backends

The browser scheme and the upstream scheme are independent.

```text
Browser wss:// → Nginx → proxy_pass http://  or  https://
```

`proxy_pass` keeps using `http://` or `https://`, there is no `ws://` scheme to
write. When the backend is `https://`, the generated config applies:

```nginx
proxy_ssl_server_name on;
proxy_ssl_verify off;
```

to the WebSocket location as well as the normal one.

### Path rules

The WebSocket path is structured input, not raw Nginx syntax.

Accepted:

```text
/ws/
/socket/
/ws/chat/
/realtime/v1/
```

Rejected:

```text
ws                       missing the leading slash
http://example.com       not a path
/                        would collide with location /
/ws/ {                   block syntax
/ws/;                    directive syntax
anything with a space, a quote, a dollar sign or a newline
```

A path without a trailing slash, such as `/ws`, is normalized to `/ws/` so the
prefix location cannot also match `/wsadmin`.

## Database Format

Registry file:

```bash
/etc/nginx/reverse-manager.db
```

Format:

```text
domain;backend_url;wildcard=yes|no;ssl=yes|no;mode=generated|manual;profile=<slug>;websocket=yes|no;websocket_path=/ws/
```

Example:

```text
example.com;http://127.0.0.1:8000;wildcard=no;ssl=yes;mode=generated;profile=django;websocket=yes;websocket_path=/ws/
```

### Compatibility with older registries

Everything after the backend URL is a `key=value` field, so rows written by
earlier versions stay valid and are never rewritten until the domain is edited.

Old row, still supported:

```text
example.com;http://127.0.0.1:8000;wildcard=no;ssl=yes
example.com;http://127.0.0.1:8000;wildcard=no;ssl=yes;mode=generated
```

Missing keys fall back to:

```text
mode=generated
profile=generic
websocket=no
websocket_path=/ws/
```

A row that does not declare the capability is an HTTP only row, so upgrading
`xemireverse` never changes the behaviour of an existing domain.

### A missing field and a corrupted field are not the same thing

The stored path is re-validated every time it is read, and the two failure
modes are handled differently on purpose.

**The key is absent.** That is a 3.5 or 3.6 row. It takes the defaults above,
which is what keeps older registries working.

**The key is present but the value does not validate.** That is corrupted
data, and it is never repaired silently. Substituting `/ws/` there would
publish a WebSocket endpoint on a path nobody configured, so instead the row is
kept exactly as stored and marked invalid:

```text
example.com   ...   websocket=yes;websocket_path=oops
```

* the domain is listed with `INVALID PATH`
* the edit screen shows the stored value and says what to do
* a missing `.conf` is not regenerated from a substituted path
* saving is refused, in generated and in manual mode
* `db_save_entry` refuses to write an invalid path while the capability is on
* reading the row never rewrites the registry

The operator clears it by setting a valid path, edit option 5, or by disabling
WebSocket support, edit option 4. With the capability disabled the field is
inert and is normalized to the default on the next save, so a corrupted value
never blocks an unrelated edit forever.

## Files and Directories

| Path                            | Purpose                 |
| ------------------------------- | ----------------------- |
| `/usr/local/bin/xemireverse`    | Main script             |
| `tests/run_tests.sh`            | Verification suite      |
| `/etc/nginx/conf.d`             | Nginx vhost configs     |
| `/etc/nginx/reverse-manager.db` | Domain registry         |
| `/etc/ssl/cloudflare`           | SSL certificate storage |
| `/var/backups/reverse-manager`  | Automatic backups       |
| `/var/log/reverse-manager.log`  | Operation logs          |

## SSL Certificates

Certificates are stored as:

```bash
/etc/ssl/cloudflare/example.com.pem
/etc/ssl/cloudflare/example.com.key
```

If SSL is enabled and no certificate exists, the tool can generate a self signed certificate automatically.

For production, recommended certificates are:

* Cloudflare Origin CA
* Let’s Encrypt
* Commercial SSL certificate

## Safety Features

Before applying changes, the tool:

1. Creates a backup
2. Writes configs safely
3. Sanitizes CRLF and non printable characters
4. Blocks unresolved placeholder tokens
5. Runs `nginx -t`
6. Reloads Nginx only if validation passes
7. Rolls back automatically if validation or reload fails

Forbidden placeholder example:

```text
__PROXY_TIMEOUT__
```

## Menu Options

### 1. Create domain

Creates a new registry entry and Nginx config.

You will be asked for:

* domain
* deployment type
* backend URL
* wildcard yes/no
* SSL yes/no
* WebSocket support yes/no
* WebSocket path, when WebSocket support is enabled

### 2. List domains

Displays all registered domains.

### 3. View domain conf

Shows the generated Nginx config for a selected domain.

### 4. Edit domain

Allows you to:

* change backend URL
* toggle wildcard
* toggle SSL
* toggle WebSocket support
* change the WebSocket path
* manually edit full config
* save and apply safely
* discard changes

Enabling, disabling or repointing WebSocket support regenerates the vhost and
applies it through the usual backup, `nginx -t` and rollback path. Disabling it
removes the WebSocket location from the generated file.

Structured edits, including the WebSocket ones, mark the entry as `generated`.
If the entry was in `manual` mode the tool warns that saving will replace the
hand written file, exactly as it already did for backend, wildcard and SSL
changes. An entry left untouched in `manual` mode keeps its file.

### 5. Delete domain

Deletes:

* registry entry
* Nginx config file
* associated `.pem` certificate
* associated `.key` file

### 6. Test Nginx

Runs:

```bash
nginx -t
```

### 7. Safe reload Nginx

Creates a backup, validates Nginx, reloads safely, and rolls back on failure.

### 8. Audit conf.d

Checks `.conf` files for:

* CRLF characters
* unresolved placeholders
* non printable characters

### 9. Sanitize conf.d

Removes CRLF and non printable characters from `.conf` files.

A backup is created before changes.

### 10. Environment check

Shows:

* nginx path
* reload method
* config path
* database path
* cert path
* backup path
* log path

## Examples

### Django

```text
Domain: app.example.com
Backend: http://127.0.0.1:8000
Wildcard: no
SSL: yes
```

### Flask or FastAPI

```text
Domain: api.example.com
Backend: http://127.0.0.1:5000
Wildcard: no
SSL: yes
```

### WordPress or CWP

```text
Domain: example.com
Backend: http://192.168.2.116:80
Wildcard: no
SSL: yes
```

### Django with realtime WebSockets

```text
Domain: realtime.example.com
Backend: http://127.0.0.1:8000
Wildcard: no
SSL: yes
WebSocket: yes
WebSocket path: /ws/
```

### Internal HTTPS panel

```text
Domain: panel.example.com
Backend: https://192.168.2.116:2083
Wildcard: no
SSL: yes
```

For HTTPS backends, the generated Nginx config enables:

```nginx
proxy_ssl_server_name on;
proxy_ssl_verify off;
```

## Tests

The repository ships a verification suite that sources the script, redirects
every path into a temporary sandbox and checks the generated output. It needs
no root and touches no system file.

```bash
bash tests/run_tests.sh
```

It covers:

* an HTTP domain renders without any upgrade header
* a WebSocket domain renders the extra location with `Upgrade` and
  `Connection "upgrade"`, while `location /` keeps `Connection ""`
* custom paths such as `/socket/` and `/ws/chat/`
* SSL vhosts and HTTPS backends combined with WebSockets
* WebSocket path validation, including injection attempts
* legacy registry rows from 3.5 and 3.6 loading as `websocket=no`
* enabling, repointing and disabling the capability on an existing domain
* the CRLF, non printable and forbidden placeholder guarantees
* structural checks such as balanced braces and no duplicate directive in a
  block

`shellcheck` and `nginx -t` run automatically when those binaries are present,
and are reported as `SKIP` when they are not. The `nginx -t` case builds a
throwaway `nginx.conf` around the generated vhosts, so it validates them
without touching the real configuration. Nginx warnings are reported as `NOTE`
even when `nginx -t` exits successfully.

### Continuous integration

`.github/workflows/verify.yml` runs the same suite on an Ubuntu runner with
`nginx` and `shellcheck` installed, for pushes to `main` and to the feature
branch, and for pull requests targeting `main`. CI fails if any check reports
`SKIP`, so `nginx -t` and `shellcheck` cannot silently go unexecuted there.
It is verification only, with no deployment, no server access and no secrets.

## Troubleshooting

Test Nginx manually:

```bash
nginx -t
```

Check Nginx status:

```bash
systemctl status nginx
```

Check recent logs:

```bash
tail -n 50 /var/log/reverse-manager.log
```

Follow logs live:

```bash
tail -f /var/log/reverse-manager.log
```

Test backend connectivity:

```bash
curl -I http://127.0.0.1:8000
```

Or:

```bash
curl -I http://192.168.2.116:80
```

If the backend does not respond from the reverse proxy server, Nginx will not be able to proxy to it.

### WebSocket returns 404 or closes immediately

Check the handshake reaching the backend:

```bash
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  http://127.0.0.1:8000/ws/
```

A healthy ASGI backend answers `101 Switching Protocols`. If the backend is
fine but the public URL is not, confirm that:

* the domain has the WebSocket capability enabled, option 4 in Edit domain
* the configured path matches the application routing, `/ws/` against `/ws/`
* the generated file contains the `location` for that path, menu option 3
* Cloudflare has WebSockets enabled for the zone

## Cloudflare Recommended Mode

Recommended Cloudflare SSL mode:

```text
Full
```

or:

```text
Full strict
```

Typical production flow:

```text
Browser HTTPS → Cloudflare HTTPS → Reverse Nginx HTTPS → Backend HTTP or HTTPS
```

## Backup and Rollback

Backups are stored in:

```bash
/var/backups/reverse-manager
```

A backup is created before destructive or risky actions such as:

* create
* edit
* delete
* sanitize
* reload

If validation fails, the previous state is restored automatically.

## Notes

Run as root:

```bash
sudo xemireverse
```

Do not edit generated files manually unless needed.

Use manual mode from the tool if you need custom Nginx directives.

## Version

```text
Reverse Manager 3.7.0
```

```
