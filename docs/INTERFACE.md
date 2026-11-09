## The Interface Contract (do this in Week 1, it saves the project)

| Contract item | Agreed value |
|---|---|---|---|
| VM1 hostname / IP | `todo-primary` / `192.168.56.10` |
| VM2 hostname / IP | `todo-backup` / `192.168.56.20` | 
| App listen address | `127.0.0.1:5000` | M2 | M1, M4 |
| Env file path | `/etc/taskops/taskops.env` |
| Database | `taskops` |
| Database role | `taskops_app` (CRUD on `public.tasks`) |
| DB listen | `127.0.0.1:5432` |
