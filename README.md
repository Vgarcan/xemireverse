# xemireverse `reverse-manager` — Nginx Reverse Proxy Controller

Tool for managing Nginx reverse proxy configurations with backend mappings, SSL handling, subdomain support, and Cloudflare compatibility.

---

## **Table of Contents**

* [Overview](#overview)
* [System Architecture](#system-architecture)
* [Supported Backends](#supported-backends)
* [Features](#features)
* [Certificate Handling](#certificate-handling)
* [Domain Registry](#domain-registry)
* [Backend Rules](#backend-rules)
* [Subdomains & Wildcards](#subdomains--wildcards)
* [Cloudflare Notes](#cloudflare-notes)
* [Generated Nginx Config](#generated-nginx-config)
* [Directories & Files](#directories--files)
* [.Installation](#installation)
* [.Dependencies](#dependencies)
* [.Usage](#usage)

  * [Create Domain](#create-domain)
  * [Edit Domain](#edit-domain)
  * [Delete Domain](#delete-domain)
  * [Validate Config](#validate-config)
  * [Reload Nginx](#reload-nginx)
* [.Examples](#examples)
* [CWP Integration](#cwp-integration)
* [Backup & Restore](#backup--restore)
* [Troubleshooting](#troubleshooting)
* [Future Extensions](#future-extensions)
* [License](#license)

---

## Overview

`reverse-manager` provides an interactive CLI for defining reverse proxy routes:

```
Internet → Cloudflare → Reverse Nginx → Backend service
```

Designed for environments hosting multiple apps or subdomains including:

* static sites
* Django / Flask / Node apps
* WordPress / PHP
* private internal services

Primary goal: avoid manual Nginx editing per domain.

---

## System Architecture

Proxy topology (recommended):

```
┌──────────┐      ┌──────────────┐      ┌───────────────────┐
│ Internet │ ───▶ │  Cloudflare  │ ───▶ │ Reverse (Nginx)   │
└──────────┘      └──────────────┘      └───────────────────┘
                                              │
                                              ▼
                                       ┌─────────────┐
                                       │ Backend App │
                                       └─────────────┘
```

Reverse can terminate TLS or forward it downstream.

Backends typically run HTTP in LAN for simplicity.

---

## Supported Backends

| Type              | Example            |
| ----------------- | ------------------ |
| Static            | CWP or Nginx local |
| PHP/WordPress     | Apache 8181        |
| Django/Gunicorn   | 9001               |
| FastAPI/Node      | custom port        |
| HTTPS internal    | Panel, API         |
| Cloudflare origin | Full/Strict        |

---

## Features

✔ Domain → backend mapping
✔ Subdomains / wildcards
✔ SSL on/off per domain
✔ Certificate auto-generation
✔ Backend HTTPS (optional)
✔ Cloudflare-compatible
✔ Nginx validate & reload
✔ Safe delete (DB + conf)
✔ Registry-based management

---

## Certificate Handling

Certificates stored in:

```
/etc/ssl/cloudflare/
```

Naming:

```
<domain>.pem
<domain>.key
```

Workflow:

1. detect existing cert
2. reuse or regen
3. allow self-signed
4. future support: Cloudflare Origin CA

---

## Domain Registry

Persistent DB:

```
/etc/nginx/reverse-manager.db
```

Format:

```
domain;backend;wildcard=yes|no;ssl=yes|no
```

Example:

```
example.com;192.168.2.120:9001;wildcard=no;ssl=yes
```

---

## Backend Rules

Backend URL formats:

**HTTP (default):**

```
192.168.2.120:9001
```

**HTTPS:**

```
https://127.0.0.1:2083
```

Convention:

* omit protocol unless backend is HTTPS
* Cloudflare reverse uses HTTPS externally only

---

## Subdomains & Wildcards

Examples:

```
styles.example.com → backend: 192.168.2.120:80
```

Wildcard example:

```
*.example.com → backend: 192.168.2.120:9001
```

Useful for SaaS and CWP hosting.

---

## Cloudflare Notes

Recommended Cloudflare settings:

| Setting  | Value               |
| -------- | ------------------- |
| SSL mode | Full or Full Strict |
| HTTP2    | ON                  |
| HTTP3    | Optional            |
| Proxy    | ON                  |
| Caching  | Standard            |

Cloudflare handles:

* TLS edge
* DNS resolution
* optional caching + WAF

Reverse handles LAN routing.

---

## Generated Nginx Config

Example (HTTP):

```nginx
server {
    listen 80;
    server_name example.com www.example.com;

    location / {
        proxy_pass http://192.168.2.120:9001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

HTTPS with cert:

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate /etc/ssl/cloudflare/example.com.pem;
    ssl_certificate_key /etc/ssl/cloudflare/example.com.key;

    location / {
        proxy_pass http://192.168.2.120:9001;
    }
}
```

---

## Directories & Files

| Path                             | Purpose                |
| -------------------------------- | ---------------------- |
| `/usr/local/bin/reverse-manager` | CLI tool               |
| `/etc/nginx/conf.d/`             | Generated Nginx vhosts |
| `/etc/nginx/reverse-manager.db`  | Registry               |
| `/etc/ssl/cloudflare/`           | Certificates           |

---

## Installation

Copy script to:

```
/usr/local/bin/reverse-manager
```

Make executable:

```
chmod +x /usr/local/bin/reverse-manager
```

---

## Dependencies

Runtime:

```
nginx
openssl
bash
systemd
```

---

## Usage

Start:

```
reverse-manager
```

### Create Domain

Workflow:

```
Main menu → Create domain
```

Choose:

* Domain
* Backend port
* Wildcard yes/no
* SSL yes/no

### Edit Domain

Can modify:

* backend port
* wildcard
* SSL
* certificates

### Delete Domain

Removes DB entry + conf.

### Validate Config

```
nginx -t
```

### Reload Nginx

```
systemctl reload nginx
```

---

## Examples

Static site:

```
styles.example.com → 192.168.2.120:80
```

Django:

```
app.example.com → 192.168.2.120:9001
```

Multi-port SaaS:

```
tenant1.example.com → :9002
tenant2.example.com → :9003
```

---

## CWP Integration

Suggested mappings:

| Type              | Port           |
| ----------------- | -------------- |
| Static / WP / PHP | 80             |
| Django / App      | 9001+          |
| Panel             | HTTPS internal |

CWP handles static + PHP internally via Nginx+Apache.

---

## Backup & Restore

Backup registry + certs:

```
cp /etc/nginx/reverse-manager.db .
cp -r /etc/ssl/cloudflare .
```

Restore and reload Nginx.

---

## Troubleshooting

Common checks:

```
nginx -t
systemctl status nginx
curl -I -H "Host: domain.com" http://BACKEND
```

Cloudflare issues often fixed by:

* ensuring proxy orange-cloud ON
* SSL mode Full/Strict

---

## Future Extensions

Planned:

* ACME/LetsEncrypt integration
* Cloudflare Origin CA automation
* Health checks
* Renewal automation
* GitOps + IaC
* wildcard cert manager
* multi-node reverse cluster

---

## License

Pending selection.

