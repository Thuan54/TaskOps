# The Interface Contract (Agreed System Specifications)

> **Mục đích**: Bảng thỏa thuận kỹ thuật chuẩn (Interface Contract) giữa 5 thành viên trong nhóm. Mọi thành viên bắt buộc phải tuân thủ đúng các đường dẫn, tên cổng, tên dịch vụ và phân quyền bên dưới để đảm bảo tính tương thích và tích hợp thông suốt.

---

## 1. Network & Virtual Machine Identification

| Contract Item | Agreed Value | Managed By | Depended On By |
| :--- | :--- | :---: | :---: |
| **VM1 Hostname** | `todo-primary` | M1 (Infra) | All Members |
| **VM1 Host-Only IP** | `192.168.56.10` | M1 (Infra) | All Members |
| **VM1 MagicDNS Name** | `todo-primary` (Tailnet) | M1 (Infra) | All Members |
| **VM2 Hostname** | `todo-backup` | M1 (Infra) | M4, M5 |
| **VM2 Host-Only IP** | `192.168.56.20` | M1 (Infra) | M4, M5 |
| **VM2 MagicDNS Name** | `todo-backup` (Tailnet) | M1 (Infra) | M4, M5 |

---

## 2. Ports & Local Binding Specifications

| Service | Listen Address / Port | Exposure / Restriction | Managed By |
| :--- | :--- | :--- | :---: |
| **SSH** | `*:22` (TCP) | **Strictly restricted to `tailscale0`** via UFW | M1, M2 |
| **Nginx HTTP** | `0.0.0.0:80` (TCP) | Public / 301 Redirect to HTTPS | M2 (Web) |
| **Nginx HTTPS** | `0.0.0.0:443` (TCP) | Public / TLS v1.2, v1.3 | M2 (Web) |
| **Backend App** | `127.0.0.1:5000` (TCP) | **Strictly localhost only** (reverse proxy target) | M3 (App) |
| **PostgreSQL** | `127.0.0.1:5432` (TCP) | **Strictly localhost only** (proven via `ss -tlnp`) | M1, M4 |

---

## 3. Storage & Directory Layout

| Purpose | Path | Filesystem / Permission | Managed By |
| :--- | :--- | :--- | :---: |
| **Dedicated 10GB Disk** | `/srv/backup` | `ext4`, persistent fstab via UUID | M1 (Infra) |
| **VM2 Rsync Target** | `/srv/backup/incoming/` | Mode `0775`, owner `backup_user` / team | M1, M5 |
| **Toolkit Location** | `/opt/taskops-toolkit` | Mode `0755`, owner `root:root` | M5 (DevOps) |
| **Web Root (App)** | `/var/www/taskops-app/` | Mode `0755`, owner `www-data:www-data` | M2, M3 |
| **Web Root (Status)** | `/var/www/taskops-status/` | Mode `0755`, owner `www-data:www-data` | M2, M5 |
| **SSL Certs / CA** | `/etc/ssl/taskops/` | Mode `0700`, owner `root:root` | M2 (Security) |
| **Environment Secrets** | `/etc/taskops/taskops.env` | **Mode `0600` or `0640`**, owner `root:taskops` | M3, M5 |

---

## 4. Database Credentials & Schema

| Parameter | Agreed Specification |
| :--- | :--- |
| **Database Name** | `taskops_db` |
| **Application User** | `taskops_app` (or `taskops_user`) |
| **Application Privilege** | Least Privilege: `SELECT, INSERT, UPDATE, DELETE` on `tasks` table |
| **Superuser** | `postgres` (Admin only, never used by app) |
| **Schema File** | `db/schema.sql` |
| **Permissions File** | `db/grants.sql` |

---

## 5. Systemd Units & Automation Timers

| Unit Name | Type | Description |
| :--- | :---: | :--- |
| `taskops.service` | Service | Backend Node.js process (`Restart=on-failure`, journald) |
| `taskops-backup.service` | Service | Executes `/opt/taskops-toolkit/bin/backup.sh` |
| `taskops-backup.timer` | Timer | Schedules daily backup at `02:00:00` |
| `taskops-health.service` | Service | Executes `/opt/taskops-toolkit/bin/healthcheck.sh` |
| `taskops-health.timer` | Timer | Triggers healthcheck every 5 minutes |
| `taskops-status.service` | Service | Generates `/var/www/taskops-status/status.html` |
| `taskops-status.timer` | Timer | Updates the status page at boot and every 5 minutes |
