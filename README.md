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
* [Database Format](#database-format)
* [Files and Directories](#files-and-directories)
* [SSL Certificates](#ssl-certificates)
* [Safety Features](#safety-features)
* [Menu Options](#menu-options)
* [Examples](#examples)
* [Troubleshooting](#troubleshooting)

## Overview

`xemireverse` is a Bash-based terminal tool that manages Nginx reverse proxy configurations from an interactive menu.

It creates and maintains domain mappings, generates Nginx vhost files, validates configuration before reload, creates backups, and rolls back automatically if something fails.

## Features

* Create, edit, list, view and delete reverse proxy domains
* Generate Nginx configs under `/etc/nginx/conf.d`
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

## Database Format

Registry file:

```bash
/etc/nginx/reverse-manager.db
```

Format:

```text
domain;backend_url;wildcard=yes|no;ssl=yes|no;mode=generated|manual
```

Example:

```text
example.com;http://127.0.0.1:8000;wildcard=no;ssl=yes;mode=generated
```

## Files and Directories

| Path                            | Purpose                 |
| ------------------------------- | ----------------------- |
| `/usr/local/bin/xemireverse`    | Main script             |
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

### 2. List domains

Displays all registered domains.

### 3. View domain conf

Shows the generated Nginx config for a selected domain.

### 4. Edit domain

Allows you to:

* change backend URL
* toggle wildcard
* toggle SSL
* manually edit full config
* save and apply safely
* discard changes

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
Reverse Manager 3.6.0
```

```
