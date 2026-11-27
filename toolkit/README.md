## Folder structure
```
toolkit/
├── toolkit.sh                    # menu entrypoint — dispatch only
├── lib/
│   ├── common.sh                 # set -euo pipefail, logging, trap, die, confirm
│   ├── config.sh                 # loads /etc/taskops-toolkit/toolkit.conf
│   └── alert.sh                  # send_alert() — msmtp or Telegram
├── bin/
│   ├── deploy.sh
│   ├── backup.sh
│   ├── restore.sh
│   ├── healthcheck.sh
│   ├── logrotate.sh
│   └── status.sh                   # Generates /var/www/taskops-status/status.html
├── conf/
│   ├── toolkit.conf              # paths, retention days, rsync target
│   └── health.conf               # thresholds
└── systemd/
    ├── taskops.service
    ├── taskops-backup.service
    ├── taskops-backup.timer
    ├── taskops-health.service
    ├── taskops-health.timer
    ├── taskops-status.service
    └── taskops-status.timer

```

The backend runs as the unprivileged `taskops` account. Its unit reads
`/etc/taskops/taskops.env`; use `conf/taskops.env.example` as the template,
owned by `root:taskops` with mode `0640`. See `app/README.md` for setup.

## Log rotation and status page (F14)

Install `logrotate` and copy `conf/taskops-logrotate.conf` to
`/etc/logrotate.d/taskops`. The `logrotate` toolkit command then uses the
system-wide logrotate state, rotating `/var/log/taskops/toolkit.log` weekly,
keeping four rotations, and compressing older files.

Install `systemd/taskops-status.service` and
`systemd/taskops-status.timer` into `/etc/systemd/system`, then enable the
timer with `systemctl enable --now taskops-status.timer`. It publishes a fresh
`/var/www/taskops-status/status.html` at boot and every five minutes.
`status.local` serves this generated report first; the bundled `index.html`
is only a fallback that does not claim services are healthy.