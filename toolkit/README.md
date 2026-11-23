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
│   └── logrotate.sh
├── conf/
│   ├── toolkit.conf              # paths, retention days, rsync target
│   └── health.conf               # thresholds
└── systemd/
    ├── taskops-backup.service
    ├── taskops-backup.timer
    ├── taskops-health.service
    └── taskops-health.timer

```