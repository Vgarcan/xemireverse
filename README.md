Perfecto. Vamos a **actualizar tu documento** para que refleje la versión “pro” que ya tienes (la **3.6.0**, en inglés), con:

* **Safe reload** con backup y rollback
* **Audit y sanitize** de `conf.d`
* Protección contra placeholders tipo `__PROXY_TIMEOUT__`
* **Delete domain** que también borra **archivos asociados**, conf y certificados
* Paths nuevos de backup y log
* Ajustes de UI (badges, colores, TUI)

Abajo te dejo el documento **ya actualizado** en Markdown, con **TOC clicable**.

---

# `xemireverse` — Reverse Manager for Nginx

Interactive CLI tool to manage Nginx reverse proxy vhosts for multiple backends (static sites, WordPress/PHP, Django, panels, etc.), with Cloudflare in front and optional SSL termination on the reverse.

Designed for setups like:

```text
Internet → Cloudflare → Reverse Nginx (this script) → Backend (CWP / Django / etc.)
```

---

## Table of Contents

* [Overview](#overview)
* [What the script actually does](#what-the-script-actually-does)
* [Architecture and Philosophy](#architecture-and-philosophy)
* [System Requirements](#system-requirements)
* [Installation](#installation)
* [First Run: Environment Check](#first-run-environment-check)
* [Core Concepts](#core-concepts)

  * [Domain registry](#domain-registry)
  * [Backend URL format](#backend-url-format)
  * [Wildcard flag](#wildcard-flag)
  * [SSL flag (reverse)](#ssl-flag-reverse)
* [Security and Safety Features](#security-and-safety-features)

  * [Atomic writes](#atomic-writes)
  * [No placeholder tokens allowed](#no-placeholder-tokens-allowed)
  * [Audit and sanitize conf.d](#audit-and-sanitize-confd)
  * [Safe reload with backup and rollback](#safe-reload-with-backup-and-rollback)
  * [Logging](#logging)
* [Certificate Handling in Practice](#certificate-handling-in-practice)

  * [Where certs live](#where-certs-live)
  * [What happens when you enable SSL](#what-happens-when-you-enable-ssl)
  * [Re-using vs regenerating certs](#re-using-vs-regenerating-certs)
* [Cloudflare and SSL Modes](#cloudflare-and-ssl-modes)
* [Backend Types and Port Examples](#backend-types-and-port-examples)
* [Using the Menu](#using-the-menu)

  * [Option 1: Create domain](#option-1-create-domain)
  * [Option 2: List domains](#option-2-list-domains)
  * [Option 3: View domain Nginx config](#option-3-view-domain-nginx-config)
  * [Option 4: Edit domain](#option-4-edit-domain)
  * [Option 5: Delete domain](#option-5-delete-domain)
  * [Option 6: Test Nginx configuration](#option-6-test-nginx-configuration)
  * [Option 7: Safe reload Nginx](#option-7-safe-reload-nginx)
  * [Option 8: Audit conf.d](#option-8-audit-confd)
  * [Option 9: Sanitize conf.d](#option-9-sanitize-confd)
  * [Option 10: Environment check](#option-10-environment-check)
* [Typical Workflows](#typical-workflows)

  * [Workflow A: Simple HTTP backend (static or PHP)](#workflow-a-simple-http-backend-static-or-php)
  * [Workflow B: Django backend on custom port](#workflow-b-django-backend-on-custom-port)
  * [Workflow C: CWP AutoSSL plus Reverse SSL plus HTTPS backend](#workflow-c-cwp-autossl-plus-reverse-ssl-plus-https-backend)
* [Files and Directories](#files-and-directories)
* [Backup and Restore](#backup-and-restore)
* [Troubleshooting](#troubleshooting)
* [FAQ](#faq)
* [Future Ideas](#future-ideas)

---

## Overview

`xemireverse` is a Bash-based interactive CLI that:

* keeps a **registry** of domains and their backends in a simple DB file
* generates **Nginx vhost** configs under `/etc/nginx/conf.d`
* optionally **terminates SSL** on the reverse with per-domain certificates
* supports **safe apply**, meaning it validates Nginx before reload and can rollback
* includes **audit and sanitize** tools to detect and fix broken config files
* works well with **Cloudflare in front**
* supports **LAN backends** (CWP, Django, internal apps)

Goal: you should **rarely** need to hand-edit vhost configs. The script keeps everything consistent, validated, and easy to recover.

---

## What the script actually does

Key paths and files:

* `NGINX_CONF_DIR="/etc/nginx/conf.d"`
* `DB_FILE="/etc/nginx/reverse-manager.db"`
* `CERT_DIR="/etc/ssl/cloudflare"`
* `BACKUP_DIR="/var/backups/reverse-manager"`
* `LOG_FILE="/var/log/reverse-manager.log"`

DB format, one line per domain:

```text
domain;backend_url;wildcard=yes|no;ssl=yes|no
```

Actions provided:

* Create, list, view, edit, delete domain mappings
* Generate Nginx configs for:

  * HTTP only
  * HTTP redirect to HTTPS plus HTTPS vhost
* Generate per-domain self-signed certs if needed
* Audit and sanitize existing config files
* Run Nginx validation tests
* Reload Nginx using a safe workflow

---

## Architecture and Philosophy

Recommended topology:

```text
Client → Cloudflare → Reverse (this host) → Backend (CWP / Django / etc.)
```

Responsibilities:

* Cloudflare:

  * public DNS
  * edge TLS
  * WAF and caching (optional)
* Reverse:

  * routes traffic to backends
  * optionally terminates TLS on 443
  * is a single control point for all domains
* Backend:

  * serves the app
  * typically on a private IP or LAN
  * can be HTTP or HTTPS

---

## System Requirements

* Linux host with:

  * `bash`
  * `nginx`
  * `openssl`
  * `systemd` for `systemctl reload nginx`
* Root privileges required
* Nginx must include `/etc/nginx/conf.d/*.conf` (typical default)

Optional:

* SELinux tools, if you want to manage `httpd_can_network_connect`

---

## Installation

1. Save as:

```bash
/usr/local/bin/xemireverse
```

2. Make executable:

```bash
chmod +x /usr/local/bin/xemireverse
```

3. Run as root:

```bash
sudo xemireverse
```

---

## First Run: Environment Check

Menu option:

> `10) Environment check`

This shows:

* nginx binary presence
* nginx systemd unit presence
* important paths used by the tool
* a quick sanity check overview

---

## Core Concepts

### Domain registry

Stored here:

```text
/etc/nginx/reverse-manager.db
```

Line format:

```text
domain;backend_url;wildcard=yes|no;ssl=yes|no
```

Example:

```text
site.example.com;http://192.168.2.116:9001;wildcard=no;ssl=yes
api.example.com;https://192.168.2.50:8443;wildcard=no;ssl=yes
```

### Backend URL format

You can enter with or without protocol. The tool normalizes.

Examples:

| You type                     | Stored as                    |
| ---------------------------- | ---------------------------- |
| `192.168.2.116:80`           | `http://192.168.2.116:80`    |
| `http://192.168.2.116:9001`  | `http://192.168.2.116:9001`  |
| `https://192.168.2.120:8443` | `https://192.168.2.120:8443` |
| `192.168.2.116`              | `http://192.168.2.116`       |

Backend HTTPS behavior:

If backend is `https://...`, the generated vhost enables:

```nginx
proxy_ssl_server_name on;
proxy_ssl_verify off;
```

This avoids failures when the backend uses self-signed or mismatched certs.

### Wildcard flag

If `wildcard=yes`:

```nginx
server_name domain.com *.domain.com;
```

If `wildcard=no`:

```nginx
server_name domain.com www.domain.com;
```

### SSL flag (reverse)

If `ssl=no`:

* only HTTP vhost on port 80 is generated

If `ssl=yes`:

* port 80 vhost redirects to HTTPS
* port 443 vhost terminates TLS using certs from `/etc/ssl/cloudflare`

---

## Security and Safety Features

### Atomic writes

Configs are written to a temporary file and moved into place, preventing half-written configs that break Nginx.

### No placeholder tokens allowed

The tool blocks “unresolved placeholders” in configs such as:

```text
__PROXY_TIMEOUT__
```

This directly prevents the classic error:

```text
proxy_read_timeout directive invalid value
```

### Audit and sanitize conf.d

Audit detects:

* CRLF
* non-printable characters
* forbidden placeholder tokens

Sanitize removes:

* CRLF
* non-printable characters

This is useful if a file was edited from Windows or copied incorrectly.

### Safe reload with backup and rollback

Before applying changes:

* creates a backup of `/etc/nginx/conf.d` under `/var/backups/reverse-manager`

On apply:

* runs `nginx -t`
* reloads Nginx only if the test passes
* if test or reload fails, it restores the backup and tries to recover

### Logging

All operations are logged to:

```text
/var/log/reverse-manager.log
```

Useful for debugging and auditing changes.

---

## Certificate Handling in Practice

### Where certs live

Per-domain certs:

```text
/etc/ssl/cloudflare/<domain>.pem
/etc/ssl/cloudflare/<domain>.key
```

### What happens when you enable SSL

When SSL is enabled:

* if cert and key exist, you can keep or regenerate
* if missing, it generates a self-signed cert automatically

### Re-using vs regenerating certs

Re-use if you placed:

* Cloudflare Origin CA
* Let’s Encrypt
* any valid cert

Regenerate if you just need:

* quick internal testing

---

## Cloudflare and SSL Modes

Typical recommendation:

* Cloudflare SSL mode:

  * Full or Full strict
* Reverse:

  * terminates TLS using local cert files
* Backend:

  * HTTP for LAN simplicity
  * HTTPS if you want encryption reverse to backend

---

## Backend Types and Port Examples

| Type               | Example backend URL          |
| ------------------ | ---------------------------- |
| WordPress on CWP   | `192.168.2.116:80`           |
| Django app         | `192.168.2.116:9001`         |
| Another Django     | `192.168.2.116:9002`         |
| CWP panel          | `https://192.168.2.116:2083` |
| Internal API HTTPS | `https://192.168.2.200:8443` |

---

## Using the Menu

Run:

```bash
xemireverse
```

Menu options:

* 1 Create domain
* 2 List domains
* 3 View domain conf
* 4 Edit domain
* 5 Delete domain
* 6 Test Nginx
* 7 Safe reload Nginx
* 8 Audit conf.d
* 9 Sanitize conf.d
* 10 Environment check
* 0 Exit

### Option 1: Create domain

Creates DB entry and config file, optionally certs, then applies safely.

### Option 2: List domains

Shows DB entries.

### Option 3: View domain Nginx config

Views the generated conf in `less`.

### Option 4: Edit domain

Allows changing backend, wildcard, SSL settings. Then regenerates and safely applies.

### Option 5: Delete domain

Deletes:

* DB entry
* Nginx conf `/etc/nginx/conf.d/<domain>.conf`
* associated cert files:

  * `/etc/ssl/cloudflare/<domain>.pem`
  * `/etc/ssl/cloudflare/<domain>.key`

This matches “delete all associated files” for the domain.

### Option 6: Test Nginx configuration

Runs:

```bash
nginx -t
```

### Option 7: Safe reload Nginx

Creates a backup and attempts a safe apply with rollback if needed.

### Option 8: Audit conf.d

Reports problems in existing conf files.

### Option 9: Sanitize conf.d

Cleans CRLF and non-printable characters and rolls back if Nginx validation fails.

### Option 10: Environment check

Shows OS, Nginx presence, and key directories.

---

## Typical Workflows

### Workflow A: Simple HTTP backend (static or PHP)

1. Create domain
2. Backend `192.168.x.x:80`
3. SSL yes for HTTPS on reverse
4. Safe reload

### Workflow B: Django backend on custom port

1. Backend `192.168.x.x:9001`
2. SSL yes for HTTPS on reverse
3. Use Host header checks if needed

### Workflow C: CWP AutoSSL plus Reverse SSL plus HTTPS backend

1. Start with backend pointing to CWP HTTP `:80`
2. Let CWP generate AutoSSL
3. Edit backend to `https://<ip>:443` if desired
4. Safe reload

---

## Files and Directories

| Path                              | Purpose                 |
| --------------------------------- | ----------------------- |
| `/usr/local/bin/xemireverse`      | main CLI script         |
| `/etc/nginx/conf.d/<domain>.conf` | generated vhost configs |
| `/etc/nginx/reverse-manager.db`   | domain registry         |
| `/etc/ssl/cloudflare/`            | reverse TLS certs       |
| `/var/backups/reverse-manager/`   | automatic backups       |
| `/var/log/reverse-manager.log`    | logs                    |

---

## Backup and Restore

Backups are created automatically before applying changes.

Manual backup:

```bash
cp /etc/nginx/reverse-manager.db /root/reverse-manager.db.backup
cp -r /etc/ssl/cloudflare /root/cloudflare-certs-backup
cp -r /etc/nginx/conf.d /root/nginx-conf-backup
```

---

## Troubleshooting

Common commands:

```bash
nginx -t
systemctl status nginx
journalctl -xeu nginx.service
```

Test backend directly:

```bash
curl -I -H "Host: yourdomain.com" http://BACKEND_IP:PORT
```

---

## FAQ

**Q: Do I need to type `http://` for backend URLs**
No. The tool adds it automatically unless you explicitly use `https://`.

**Q: Does this encrypt reverse to backend traffic**
Only if the backend URL starts with `https://`.

**Q: When I delete a domain, does it remove certs too**
Yes. It removes the vhost config and the `.pem` and `.key` files for that domain.

---

## Future Ideas

* CLI non-interactive mode, apply from command line
* File lock to prevent concurrent runs
* Cloudflare real IP and trusted proxy config
* Health checks to backends before applying
* Template types for WordPress, Django, static

---

Si quieres, te lo dejo todavía más “manual de producto” añadiendo:

* una sección de “Version history” (3.3, 3.5, 3.6)
* y un “Quick start” de 10 líneas para cuando tengas prisa
