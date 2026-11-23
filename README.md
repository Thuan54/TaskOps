
# TaskOps — To-Do Application and Linux Operations

## 1. Project direction

TaskOps is **one complete system**. It combines a simple To-Do app with a secure web server, a restricted database, and tools for deployment, backup, recovery, monitoring, and log management. It runs on **two VMs**: one for the main app and one for backups.

The main focus is the Linux administration behind it, including secure deployment, automatic rollback, backup and recovery, monitoring, and system hardening.

**End-to-end request path:**
```
Browser / curl
    │
    ▼
Nginx (taskops.local, status.local) — HTTPS 443, HTTP→HTTPS redirect
    │
    ▼  proxy_pass
NodeJS  127.0.0.1:5000  — managed by systemd (Restart=on-failure)
    │
    ▼
PostgreSQL 127.0.0.1:5432  — taskops_db, taskops_user (least privilege)
    │
    ▼  toolkit
Backup archive ── rsync ──► VM2 (taskops-backup) : /srv/backup/incoming/
                              └── retention (7 days)
                              └── health alert ──► msmtp / Telegram

```
---

## 2. Architecture
```
┌────────────────────────────────────────────────────────────────────┐
│ Host machine                                                       │
│                                                                    │
│  ┌─────────────────────────────────┐   ┌────────────────────────┐  │
│  │ VM1  taskops-primary            │   │ VM2  taskops-backup    │  │
│  │ 192.168.56.10                   │   │ 192.168.56.20          │  │
│  │                                 │   │                        │  │
│  │  Nginx :80 → :443 (redirect)    │   │  /srv/backup/incoming/ │  │
│  │   ├─ taskops.local  → app       │   │   (rsync target)       │  │
│  │   └─ status.local   → static    │   │                        │  │
│  │                                 │   │  Used for off-host     │  │
│  │  systemd: taskops.service       │   │  backup per 3-2-1 rule │  │
│  │   └─  127.0.0.1:5000            │   │                        │  │
│  │                                 │◄──┼── rsync (SSH key auth) │  │
│  │  PostgreSQL 127.0.0.1:5432      │   │                        │  │
│  │   └─ taskops_db / taskops_user  │   │                        │  │
│  │                                 │   │                        │  │
│  │  /srv/backup  (separate disk,   │   │                        │  │
│  │   /etc/fstab persistent mount)  │   │                        │  │
│  │                                 │   │                        │  │
│  │  Toolkit /opt/taskops-toolkit   │   │                        │  │
│  │   deploy | backup | restore     │   │                        │  │
│  │   healthcheck | logrotate       │   │                        │  │
│  └─────────────────────────────────┘   └────────────────────────┘  │
│                                                                    │
│  Host-Only network  192.168.56.0/24                                │
└────────────────────────────────────────────────────────────────────┘
```

---

## 3. Repository layout
```
taskops
├── README.md                      
├── docs/
│   ├── INTERFACE.md               # Define every value, path, name, port ...
│   ├── architecture.png           
│   ├── report/                    
│   └── evidence/                  
├── app/                           
│   ├── src/            # App logic
│   └── static/         # Frontend built file
├── db/                 # schema, grants, pg_hba, postgresql config 
│   ├── schema.sql  grants.sql  pg_hba.conf  postgresql.conf.diff
├── web/                           
│   ├── nginx/todo.local.conf  nginx/status.local.conf  nginx/snippets/
│   ├── tls/openssl.cnf  tls/gen-ca.sh
│   └── static/status/index.html
├── systemd/todo-app.service       
├── security/                      
│   ├── ufw.rules  sshd_config.diff  fail2ban/*.local  auditd/todo.rules
│   └── lynis/  (report + remediations.md)
├── toolkit/                       
│   ├── toolkit.sh  lib/  deploy.sh  backup.sh  restore.sh
│   ├── healthcheck.sh  logrotate.sh  health.conf  alert.sh
│   └── systemd/todo-backup.{service,timer}
└── infra/                         
    ├── fstab.diff  netplan.yaml  bootstrap-vm.sh  snapshot-notes.md
```

--- 

## 4. Security baseline (summary)

| Control | Implementation |
|---|---|
| Firewall | UFW default-deny inbound; open only 22, 80, 443 |
| SSH | Root login disabled; key auth required; `AllowUsers sv01 sv02 sv03 sv04 sv05` (or non-standard port) |
| Fail2ban | SSH jail enabled; a real ban is demonstrated |
| Auditd | Watches `/etc/passwd`, `/etc/shadow`; `ausearch` evidence in report |
| Lynis | Baseline score recorded; ≥3 remediations performed and re-scored |
| Secrets | `/etc/taskops/taskops.env` (`root:taskops`, `0640`); never committed |
| DB exposure | `listen_addresses = '127.0.0.1'`; proven with `ss -tlnp` |
| Least privilege | `taskops_user` has only `SELECT/INSERT/UPDATE/DELETE` on `tasks` |
