#!/usr/bin/env bash
# Generate the status page consumed by the status.local Nginx virtual host.
set -Eeuo pipefail

: "${STATUS_OUTPUT:=/var/www/taskops-status/status.html}"

if ! command -v systemctl >/dev/null 2>&1; then
  printf 'systemctl is required to generate the TaskOps status page\n' >&2
  exit 127
fi

output_dir="$(dirname -- "$STATUS_OUTPUT")"
mkdir -p -- "$output_dir"
tmp_file="$(mktemp "$output_dir/.status.html.XXXXXX")"
cleanup() {
  rm -f -- "$tmp_file"
}
trap cleanup EXIT

html_escape() {
  local value=$1
  value=${value//&/\&amp;}
  value=${value//</\&lt;}
  value=${value//>/\&gt;}
  value=${value//\"/\&quot;}
  value=${value//\'/\&#39;}
  printf '%s' "$value"
}

timestamp="$(date --iso-8601=seconds)"
host="$(hostname -f 2>/dev/null || hostname)"
services=("Nginx Web Server:nginx" "TaskOps Backend:taskops,taskops-app" "PostgreSQL Database:postgresql")
rows=()
failed=0

for entry in "${services[@]}"; do
  name=${entry%%:*}
  candidates=${entry#*:}
  IFS=',' read -r -a unit_candidates <<<"$candidates"
  active=0
  for unit in "${unit_candidates[@]}"; do
    if systemctl is-active --quiet "$unit"; then
      active=1
      break
    fi
  done
  if ((active)); then
    state="Operational"
    class="operational"
  else
    state="Unavailable"
    class="unavailable"
    failed=1
  fi
  rows+=("<div class=\"service-row\"><span>${name}</span><span class=\"${class}\">${state}</span></div>")
done

if ((failed)); then
  overall="Service disruption detected"
  overall_class="degraded"
else
  overall="All monitored services operational"
  overall_class="operational"
fi

{
  cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="300">
  <title>TaskOps System Status</title>
  <style>
    :root { color-scheme: light; font-family: system-ui, sans-serif; }
    body { max-width: 720px; margin: 3rem auto; padding: 0 1rem; color: #20251f; background: #f7f8f5; }
    h1 { margin-bottom: .25rem; }
    .muted { color: #687067; }
    .banner, .card { padding: 1rem 1.25rem; margin: 1rem 0; border: 1px solid #dfe3dc; border-radius: .5rem; background: white; }
    .banner { font-weight: 700; }
    .operational { color: #237a35; }
    .degraded, .unavailable { color: #a12622; }
    .service-row { display: flex; justify-content: space-between; gap: 1rem; padding: .8rem 0; border-bottom: 1px solid #eee; }
    .service-row:last-child { border-bottom: 0; }
  </style>
</head>
<body>
  <h1>TaskOps Status</h1>
HTML
  printf '  <p class="muted">Host: %s<br>Last updated: %s</p>\n' \
    "$(html_escape "$host")" "$(html_escape "$timestamp")"
  printf '  <div class="banner %s">%s</div>\n' "$overall_class" "$overall"
  printf '  <section class="card" aria-label="Core services">\n'
  printf '    <h2>Core services</h2>\n'
  printf '    %s\n' "${rows[@]}"
  printf '  </section>\n'
  printf '</body>\n</html>\n'
} >"$tmp_file"

chmod 0644 "$tmp_file"
mv -f -- "$tmp_file" "$STATUS_OUTPUT"
trap - EXIT
printf 'Status page updated: %s\n' "$STATUS_OUTPUT"
