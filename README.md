# `xemireverse` — Reverse Manager 3.3 for Nginx

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
* [Certificate Handling in Practice](#certificate-handling-in-practice)

  * [Where certs live](#where-certs-live)
  * [What happens when you enable SSL](#what-happens-when-you-enable-ssl)
  * [Re-using vs regenerating certs](#re-using-vs-regenerating-certs)
* [Cloudflare & SSL Modes](#cloudflare--ssl-modes)
* [Backend Types and Port Examples](#backend-types-and-port-examples)
* [Using the Menu](#using-the-menu)

  * [Option 1: Create domain](#option-1-create-domain)
  * [Option 2: List domains](#option-2-list-domains)
  * [Option 3: View domain Nginx config](#option-3-view-domain-nginx-config)
  * [Option 4: Edit domain](#option-4-edit-domain)
  * [Option 5: Delete domain](#option-5-delete-domain)
  * [Option 6: Test Nginx configuration](#option-6-test-nginx-configuration)
  * [Option 7: Reload Nginx](#option-7-reload-nginx)
  * [Option 8: Environment check and basic setup](#option-8-environment-check-and-basic-setup)
  * [Option 9: Help and documentation](#option-9-help-and-documentation)
* [Typical Workflows](#typical-workflows)

  * [Workflow A: Simple HTTP backend (static / PHP)](#workflow-a-simple-http-backend-static--php)
  * [Workflow B: Django backend on custom port](#workflow-b-django-backend-on-custom-port)
  * [Workflow C: CWP AutoSSL + Reverse SSL + HTTPS backend (your “option 2”)](#workflow-c-cwp-autossl--reverse-ssl--https-backend-your-option-2)
* [Files and Directories](#files-and-directories)
* [Backup & Restore](#backup--restore)
* [Troubleshooting](#troubleshooting)
* [FAQ](#faq)
* [Future Ideas](#future-ideas)

---

## Overview

`xemireverse` (Reverse Manager 3.3) is a Bash script that:

* keeps a **registry** of domains and their backends in a simple text DB
* generates **Nginx vhost .conf** files under `/etc/nginx/conf.d`
* optionally **terminates SSL** on the reverse using self-signed certs
* lets you **edit**, **test**, and **reload** Nginx from a single menu
* works nicely with **Cloudflare in front**
* works nicely with **CWP** and custom Django backends in the LAN

Goal: you should **never** need to manually hand-edit Nginx vhosts for simple reverse proxy mapping. The script remembers everything for you.

---

## What the script actually does

From the code:

* Uses:

  * `NGINX_CONF_DIR="/etc/nginx/conf.d"`
  * `DB_FILE="/etc/nginx/reverse-manager.db"`
  * `CERT_DIR="/etc/ssl/cloudflare"`

* For each domain it stores one line:

  ```text
  domain;backend_url;wildcard=yes|no;ssl=yes|no
  ```

* It can:

  * create / list / view / edit / delete domains
  * generate Nginx configs for HTTP only
  * or HTTP redirect → HTTPS + TLS termination on the reverse
  * generate self-signed certs per domain
  * reuse existing certs or overwrite them
  * run `nginx -t`
  * run `systemctl reload nginx`
  * check your environment (nginx binary, systemd, SELinux, directories)

If you forget everything, remember this:

> Run `xemireverse`, create the domain, test Nginx, reload Nginx.

---

## Architecture and Philosophy

Recommended topology:

```text
Client → Cloudflare → Reverse (this script) → Backend (CWP / Django / etc.)
```

* **Cloudflare** handles:

  * public DNS
  * edge TLS
  * optional cache/WAF

* **Reverse (this host)**:

  * terminates TLS (optional)
  * routes traffic to internal backends
  * is the single place where you see all domains and backends

* **Backend (CWP, Django, etc.)**:

  * serves the actual application
  * can be HTTP or HTTPS
  * usually lives in the LAN (192.168.x.x)

---

## System Requirements

You need:

* Linux server with:

  * `bash`
  * `nginx`
  * `openssl`
  * `systemd` (for `systemctl` reload)
* Root privileges (the script enforces this)
* Nginx configured to include `/etc/nginx/conf.d/*.conf` (default in most distros)
* Optional:

  * SELinux tools: `getsebool` / `setsebool` (script checks them)

The script also tries to detect a package manager:

* `dnf` or `yum` or `apt-get`

and can optionally install nginx if not present.

---

## Installation

1. **Copy the script**

   Save the script as:

   ```bash
   /usr/local/bin/xemireverse
   ```

2. **Make it executable**

   ```bash
   chmod +x /usr/local/bin/xemireverse
   ```

3. **Run as root**

   ```bash
   sudo xemireverse
   ```

   or:

   ```bash
   su -
   xemireverse
   ```

4. **On first run**, you can use menu option `8` (Environment check) to:

   * verify nginx binary
   * check `nginx.service`
   * ensure directories and DB file exist
   * optionally adjust SELinux for network connections

---

## First Run: Environment Check

From the main menu choose:

> `8) Environment check and basic setup`

This will:

* show OS info (from `/etc/os-release`)
* check if `nginx` binary exists

  * if not, it offers to install `nginx` using your package manager
* show `systemctl status nginx` if the unit exists
* ensure:

  * `/etc/nginx/conf.d/`
  * `/etc/ssl/cloudflare/`
  * `/etc/nginx/reverse-manager.db`
* if SELinux tools exist, it checks `httpd_can_network_connect`

  * and can enable it permanently if you confirm

If you are not sure whether the environment is ready, just run this once before creating domains.

---

## Core Concepts

### Domain registry

All configuration lives in:

```text
/etc/nginx/reverse-manager.db
```

Each line:

```text
domain;backend_url;wildcard=yes|no;ssl=yes|no
```

Example:

```text
ineedtohirethisguy.com;http://192.168.2.116:9001;wildcard=no;ssl=yes
styles.red-bazaar.com;http://192.168.2.116:80;wildcard=no;ssl=yes
myapi.example.com;https://192.168.2.50:8443;wildcard=no;ssl=yes
```

The script reads and updates this DB when you create/edit/delete domains.

---

### Backend URL format

The script uses helper functions to parse and normalize backend URLs.

**Important: you can be lazy when typing.**
The script will auto-normalise.

Examples:

| You type                     | Script stores as                      |
| ---------------------------- | ------------------------------------- |
| `192.168.2.116:80`           | `http://192.168.2.116:80`             |
| `http://192.168.2.116:9001`  | `http://192.168.2.116:9001`           |
| `https://192.168.2.120:8443` | `https://192.168.2.120:8443`          |
| `192.168.2.116`              | `http://192.168.2.116` (port implied) |

Rules:

* If you **do not** specify `http://` or `https://`, it assumes `http://`.
* It strips trailing `/`.
* It splits into:

  * `BACKEND_SCHEME` = `http` or `https`
  * `BACKEND_HOST`   = IP or hostname
  * `BACKEND_PORT`   = port or empty

When backend URL starts with `https://`, the generated Nginx config will add:

```nginx
proxy_ssl_server_name on;
proxy_ssl_verify off;
```

so TLS to the backend does not fail on self-signed or mismatched certs.

---

### Wildcard flag

If `wildcard=yes`, the generated Nginx `server_name` is:

```nginx
server_name domain.com *.domain.com;
```

If `wildcard=no`, it is:

```nginx
server_name domain.com www.domain.com;
```

Wildcard mode is useful if:

* you want multiple subdomains to hit the same backend
* or you want a catch-all

---

### SSL flag (reverse)

* `ssl=no` → only an HTTP `server` block is created on port 80
* `ssl=yes` → the script generates:

  1. an HTTP `server` on port 80 that **redirects** to HTTPS
  2. an HTTPS `server` on port 443 with `ssl_certificate` and `ssl_certificate_key` under `/etc/ssl/cloudflare/`

So “SSL yes” means **TLS terminates on the reverse**, not on the backend.

---

## Certificate Handling in Practice

### Where certs live

All reverse TLS certificates live in:

```text
/etc/ssl/cloudflare/<domain>.pem
/etc/ssl/cloudflare/<domain>.key
```

The script does **not** interact with Let’s Encrypt or Cloudflare Origin CA directly.
It only:

* checks whether `.pem` + `.key` already exist
* optionally auto-generates a self-signed cert

Later, you can replace these with:

* Cloudflare Origin CA
* Let’s Encrypt
* or any other valid certificate

as long as you keep the same paths.

---

### What happens when you enable SSL

When you create or edit a domain and choose SSL `yes`, the script:

1. Checks if:

   ```text
   /etc/ssl/cloudflare/<domain>.pem
   /etc/ssl/cloudflare/<domain>.key
   ```

   already exist.

2. If **both exist**, you see:

   * option to **use existing**
   * or **generate new self-signed and overwrite**

3. If they **do not exist**, it:

   * prints a warning
   * auto-generates a **new self-signed certificate** valid for 365 days

This is done via:

```bash
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout /etc/ssl/cloudflare/<domain>.key \
    -out   /etc/ssl/cloudflare/<domain>.pem \
    -days 365 \
    -subj "/CN=<domain>"
```

Permissions are set to `600` so only root can read them.

---

### Re-using vs regenerating certs

**Re-using** is good when:

* you have manually placed a proper cert (e.g. Origin CA)
* or you want consistency

**Regenerating** self-signed is good for quick tests, labs, or internal-only setups.

If you later copy real certs into that location, set:

* `ssl=yes` in the DB (via edit)
* and the reverse will use them without more changes.

---

## Cloudflare & SSL Modes

This script is designed with Cloudflare proxy in mind.

Typical path:

```text
Client → Cloudflare (orange cloud) → Reverse (TLS) → Backend (HTTP/HTTPS)
```

Recommended:

* Cloudflare:

  * **SSL/TLS mode**: Full or Full (strict)
  * HTTP/2: ON
  * HTTP/3: Optional
  * Proxy: ON (orange cloud)

* Reverse:

  * TLS endpoint managed by this script
  * certificatess under `/etc/ssl/cloudflare/`

* Backend:

  * HTTP for internal CWP / Django (simple)
  * HTTPS for panel APIs or more secure links

---

## Backend Types and Port Examples

Some real-world examples you might use:

| Type               | Example backend URL          |
| ------------------ | ---------------------------- |
| CWP static / PHP   | `192.168.2.116:80`           |
| WordPress on CWP   | `192.168.2.116:80`           |
| Django (gunicorn)  | `192.168.2.116:9001`         |
| Second Django app  | `192.168.2.116:9002`         |
| CWP panel          | `https://192.168.2.116:2083` |
| Webmail            | `http://127.0.0.1:2095`      |
| Internal API HTTPS | `https://192.168.2.200:8443` |

Remember:

* If you type `192.168.2.116:9001`, script stores `http://192.168.2.116:9001`
* If you need HTTPS to backend, include `https://` explicitly

---

## Using the Menu

Run:

```bash
xemireverse
```

You will see:

```text
Reverse Manager 3.3 - Nginx Reverse Proxy Control
Manage domains, backends (HTTP/HTTPS), wildcard and SSL (Cloudflare-friendly).

Main menu:

  1) Create domain
  2) List domains
  3) View domain Nginx config
  4) Edit domain
  5) Delete domain
  6) Test Nginx configuration
  7) Reload Nginx
  8) Environment check and basic setup
  9) Help and documentation
  0) Exit
```

### Option 1: Create domain

Asks for:

* Domain (no http/https → e.g. `styles.red-bazaar.com`)
* Backend URL (with or without protocol)
* Wildcard? (y/n)
* SSL at reverse? (y/n)

Then:

* stores line in the DB
* generates `/etc/nginx/conf.d/<domain>.conf`
* prints summary and suggests:

  * `6) Test Nginx configuration`
  * `7) Reload Nginx`

### Option 2: List domains

Shows all domains in DB:

```text
Domain                        Backend URL                        Wildcard   SSL
------                        -----------                        --------   ---
styles.red-bazaar.com        http://192.168.2.116:80             no         yes
ineedtohirethisguy.com       http://192.168.2.116:9001           no         yes
panel.mydomain.com           https://192.168.2.116:2083          no         yes
```

Useful to quickly remember what you have configured.

### Option 3: View domain Nginx config

* Lets you select a domain from the DB
* Opens the generated Nginx `.conf` in `less`

Useful for debugging or for copying snippets.

### Option 4: Edit domain

This is powerful and maps directly to your needs.

You can:

1. Change backend URL (raw)
2. Change backend host only
3. Change backend port only
4. Toggle wildcard yes/no
5. Toggle SSL yes/no and manage certificates

Every change:

* updates the DB line
* regenerates the `.conf`
* tells you it has updated and regenerated

Important: when you enable SSL here, it calls `setup_ssl_for_domain` again, so you can:

* reuse existing cert
* or regenerate self-signed
* or keep existing if you cancel

### Option 5: Delete domain

* Lets you select a domain
* Confirms with `y/n`
* Removes:

  * DB entry
  * `/etc/nginx/conf.d/<domain>.conf`

Does not touch certificates.

### Option 6: Test Nginx configuration

Runs:

```bash
nginx -t
```

Always do this before reloading, especially after changes.

### Option 7: Reload Nginx

Runs:

```bash
systemctl reload nginx
```

If reload fails, it prints a hint to check:

```bash
nginx -t
systemctl status nginx
```

### Option 8: Environment check and basic setup

Explained earlier. Good first step on new servers.

### Option 9: Help and documentation

Prints a mini internal help summarizing:

* DB format
* SSL behavior
* basic flow

---

## Typical Workflows

### Workflow A: Simple HTTP backend (static / PHP)

Example: `styles.red-bazaar.com` pointing to CWP static site on port 80.

1. Ensure CWP serves the site on `192.168.2.116:80`

2. From reverse, test:

   ```bash
   curl -I -H "Host: styles.red-bazaar.com" http://192.168.2.116:80
   ```

3. Run `xemireverse` → `1) Create domain`

4. Domain: `styles.red-bazaar.com`

5. Backend URL: `192.168.2.116:80`

6. Wildcard: `n`

7. SSL on reverse: `y` (if you want HTTPS at the edge)

8. `6) Test Nginx configuration`

9. `7) Reload Nginx`

Cloudflare then points `styles.red-bazaar.com` → reverse IP (orange cloud).

---

### Workflow B: Django backend on custom port

Example: `ineedtohirethisguy.com` on backend `192.168.2.116:9001`.

1. Ensure gunicorn is bound to `192.168.2.116:9001`

2. Test:

   ```bash
   curl -I -H "Host: ineedtohirethisguy.com" http://192.168.2.116:9001
   ```

3. `xemireverse` → `1) Create domain`

4. Domain: `ineedtohirethisguy.com`

5. Backend URL: `192.168.2.116:9001`

6. Wildcard: `n`

7. SSL on reverse: `y`

Now:

```text
Client → Cloudflare → Reverse (443) → Django (HTTP 9001)
```

---

### Workflow C: CWP AutoSSL + Reverse SSL + HTTPS backend (your “option 2”)

This is the one que comentabas:

> Crear el dominio apuntando al puerto 80, generar AutoSSL en CWP, y luego cambiar el backend a HTTPS (443) para que el tráfico reverse → CWP también vaya cifrado.

Checklist:

1. In `xemireverse`, create domain pointing to **HTTP** backend:

   ```text
   Domain      : styles.red-bazaar.com
   Backend URL : 192.168.2.116:80
   SSL (rev.)  : yes (if you want HTTPS on the reverse)
   ```

2. In CWP, create domain / subdomain `styles.red-bazaar.com` and enable **AutoSSL**.

3. Wait until CWP has created its own `.ssl.conf` and certificates.

4. Once CWP has SSL, edit domain in `xemireverse`:

   * Option `4) Edit domain`
   * Change backend URL to: `https://192.168.2.116:443` (or specific SSL vhost port if different)

5. `6) Test Nginx configuration`

6. `7) Reload Nginx`

Result:

```text
Client → Cloudflare (HTTPS)
       → Reverse (HTTPS termination here)
       → CWP (HTTPS on 443)
```

You get:

* full encryption end to end
* CWP still configured correctly if you ever remove the reverse in future
* AutoSSL in CWP still handles its own renewals

---

## Files and Directories

From the script:

| Path                            | Description                                  |
| ------------------------------- | -------------------------------------------- |
| `/usr/local/bin/xemireverse`    | main CLI script                              |
| `/etc/nginx/conf.d/`            | generated Nginx vhosts (`<domain>.conf`)     |
| `/etc/nginx/reverse-manager.db` | flat file registry of domains                |
| `/etc/ssl/cloudflare/`          | TLS certs and keys for reverse (`.pem/.key`) |

---

## Backup & Restore

Minimal backup:

```bash
cp /etc/nginx/reverse-manager.db /root/reverse-manager.db.backup
cp -r /etc/ssl/cloudflare /root/cloudflare-certs-backup
cp -r /etc/nginx/conf.d /root/nginx-conf-backup
```

On a fresh system, after reinstalling:

* restore DB, certs, and conf.d
* run `nginx -t`
* then `systemctl reload nginx`

---

## Troubleshooting

Some useful commands:

1. **Test Nginx config**

   ```bash
   nginx -t
   ```

2. **Check Nginx service**

   ```bash
   systemctl status nginx
   ```

3. **Test backend directly**

   ```bash
   curl -I -H "Host: yourdomain.com" http://BACKEND_IP:PORT
   ```

4. **Test through reverse (from the reverse server)**

   ```bash
   curl -I -H "Host: yourdomain.com" http://127.0.0.1
   ```

5. **If HTTPS issues with browsers**

   * verify `ssl_certificate` and `ssl_certificate_key` paths in `/etc/nginx/conf.d/<domain>.conf`
   * confirm files exist in `/etc/ssl/cloudflare/`
   * check Cloudflare SSL mode (Full/Strict)

---

## FAQ

**Q: Do I ever need to write `http://` in the backend URL?**
A: No, not required. If you omit protocol, the script assumes `http://`. You only need `https://` when the backend itself is HTTPS.

---

**Q: Can I use this with CWP AutoSSL?**
A: Yes. For AutoSSL to work, CWP needs to answer HTTP on port 80. You can initially point the reverse to `IP:80`, let CWP create its SSL, and later change the backend to `https://IP:443` if you want.

---

**Q: What happens if I disable SSL in the script?**
A: The reverse will only listen on HTTP (80), no redirect to HTTPS, and no `ssl_certificate` lines in the Nginx config.

---

**Q: Is the backend traffic encrypted?**
A:

* If backend URL starts with `http://` → **No**, plain HTTP (LAN recommended).
* If backend URL starts with `https://` → **Yes**, reverse uses HTTPS to your backend.

---

**Q: What happens if I remove the reverse in future?**

* If backend already has proper vhosts (CWP, etc.), you can point Cloudflare directly to it.
* If you relied only on reverse SSL and backend has no SSL, you will need to configure SSL on the backend first.

---

## Future Ideas

The current script already does:

* domain registry
* nginx conf generation
* self-signed certs
* environment checks
* editing backends and ports

Things you could add later if you feel like it:

* Cloudflare Origin CA certificate generation helper
* Let’s Encrypt / ACME client integration
* Health checks for backends before writing configs
* Automatic redirect patterns (e.g., force `www` or non-`www`)
* Support for multiple reverse instances / HA


