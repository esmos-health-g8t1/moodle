# Moodle 5.1 on Azure Container Apps (ACA) – Fast, Stateless Build

This project provides a **production-ready, ACA-optimized container image** for Moodle 5.1.

It is designed for:

* ⚡ Fast cold starts (2–5s)
* 🧊 Scale-to-zero compatibility
* 🔁 Stateless containers
* ☁️ Clean separation of compute, storage, and state

---

## 🧠 Architecture Overview

| Component            | Responsibility              |
| -------------------- | --------------------------- |
| Moodle Container     | PHP + Nginx (stateless app) |
| PostgreSQL           | Database                    |
| Redis                | Sessions + cache            |
| Azure Files / Volume | `moodledata`                |

**Key principle:**

> The container is disposable. All state lives outside.

---

## 🚀 Features

* ✅ Moodle 5.1 baked into the image (no runtime git)
* ✅ No install/upgrade during container startup
* ✅ Redis-backed sessions (required for scaling)
* ✅ OPcache + APCu enabled
* ✅ Minimal Alpine-based image
* ✅ Nginx + PHP-FPM (no supervisor)

---

## 📦 Project Structure

```
.
├── Dockerfile
├── docker-compose.yml
├── nginx.conf
├── entrypoint.sh
├── config.php
└── README.md
```

---

## 🐳 Local Development (Docker Compose)

### 1. Build and start services

```bash
docker compose up --build
```

### 2. Access Moodle

```
http://localhost:8080
```

---

## ⚠️ First-Time Setup (Required)

This image does NOT auto-install Moodle (by design).

Run once:

```bash
docker exec -it moodle-app sh
```

Then:

```bash
php admin/cli/install_database.php \
  --lang=en \
  --adminuser=admin \
  --adminpass=Admin123! \
  --adminemail=admin@example.com \
  --fullname="Moodle" \
  --shortname="Moodle" \
  --agree-license
```

---

## 🔧 Environment Variables

### Core

| Variable   | Description            |
| ---------- | ---------------------- |
| MOODLE_URL | Public URL of the site |

### Database

| Variable | Description         |
| -------- | ------------------- |
| DB_TYPE  | `pgsql` or `mysqli` |
| DB_HOST  | Database host       |
| DB_PORT  | Database port       |
| DB_NAME  | Database name       |
| DB_USER  | Database user       |
| DB_PASS  | Database password   |

### Redis

| Variable   | Description    |
| ---------- | -------------- |
| REDIS_HOST | Redis hostname |

---

## ☁️ Deployment to Azure Container Apps

### Required Services

* Azure Container Apps
* Azure Database for PostgreSQL (or MySQL)
* Azure Cache for Redis
* Azure Files (mounted to `/var/www/moodledata`)

---

### Scaling Configuration

```yaml
minReplicas: 0
maxReplicas: 10
```

Use **HTTP scaling**, not CPU-based scaling.

---

## 🧊 Scale-to-Zero Design Notes

To support scale-to-zero:

* ❌ No filesystem sessions

* ❌ No runtime installs

* ❌ No mutable container state

* ✅ Redis sessions

* ✅ External DB

* ✅ External storage

---

## ⚡ Performance Optimizations

* OPcache enabled with aggressive settings
* APCu for local caching
* Reduced image size via Alpine
* No runtime dependency resolution

---

## 🔁 Upgrades

Do NOT upgrade during container startup.

Instead:

```bash
php admin/cli/upgrade.php
```

Run this via:

* Azure Container Apps Job
* CI/CD pipeline

---

## 🧪 Health Check

Recommended endpoint:

```
/login/index.php
```

---

## 🔐 Security Notes

* Do NOT use default credentials in production
* Restrict database access to private network
* Use managed identities or secrets manager where possible

---

## 🧠 Philosophy

This image follows a strict rule:

> If it slows down cold start, it does not belong in runtime.

---

## 🏁 Summary

| Goal          | Status |
| ------------- | ------ |
| Fast startup  | ✅      |
| Scale-to-zero | ✅      |
| Stateless     | ✅      |
| ACA-ready     | ✅      |

---

## 🙌 Final Note

This is not a “flexible dev container.”

It is a **cloud-native, production-first build** optimized for modern platforms like Azure Container Apps.

Treat it like infrastructure, not a pet server.
