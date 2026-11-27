#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

echo "=== TaskOps Nginx & TLS Provisioning ==="

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

# 1. Generate & install TLS certificates
echo "[1/6] Generating TLS certificates in /etc/ssl/taskops/..."
bash "${SCRIPT_DIR}/tls/gen-ca.sh" -d /etc/ssl/taskops -t

# 2. Copy Nginx snippets
echo "[2/6] Installing Nginx configuration snippets..."
mkdir -p /etc/nginx/snippets
cp -f "${SCRIPT_DIR}/nginx/snippets/"*.conf /etc/nginx/snippets/

# 3. Install virtual host configurations
echo "[3/6] Installing Nginx vhosts..."
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
cp -f "${SCRIPT_DIR}/nginx/taskops.local.conf" /etc/nginx/sites-available/
cp -f "${SCRIPT_DIR}/nginx/status.local.conf" /etc/nginx/sites-available/

ln -sf /etc/nginx/sites-available/taskops.local.conf /etc/nginx/sites-enabled/taskops.local.conf
ln -sf /etc/nginx/sites-available/status.local.conf /etc/nginx/sites-enabled/status.local.conf

# Remove default site if exists
if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# 4. Set up web document roots
echo "[4/6] Setting up web root directories..."
mkdir -p /var/www/taskops-app /var/www/taskops-status

# Deploy static status page
cp -f "${SCRIPT_DIR}/static/status/index.html" /var/www/taskops-status/index.html

# Deploy React static frontend if built
if [[ -d "${REPO_ROOT}/app/static" ]]; then
    echo "Deploying built React app from app/static/ to /var/www/taskops-app/..."
    cp -rf "${REPO_ROOT}/app/static/"* /var/www/taskops-app/
else
    echo "Notice: app/static not found. Creating placeholder index.html in /var/www/taskops-app/..."
    cat <<'EOF' > /var/www/taskops-app/index.html
<!DOCTYPE html>
<html>
<head><title>TaskOps App</title></head>
<body><h1>TaskOps App - Awaiting frontend build</h1></body>
</html>
EOF
fi

# Set proper ownership and permissions
chown -R www-data:www-data /var/www/taskops-app /var/www/taskops-status
chmod -R 0755 /var/www/taskops-app /var/www/taskops-status

# 5. Add local domain resolution to /etc/hosts if missing
echo "[5/6] Ensuring /etc/hosts contains taskops.local and status.local..."
for domain in taskops.local status.local; do
    if ! grep -qE "\b${domain}\b" /etc/hosts; then
        echo "127.0.0.1 ${domain}" >> /etc/hosts
        echo "Added 127.0.0.1 ${domain} to /etc/hosts"
    fi
done

# 6. Test and reload Nginx
echo "[6/6] Validating Nginx configuration..."
nginx -t

echo "Reloading Nginx service..."
systemctl reload nginx || systemctl restart nginx

echo ""
echo "=== Nginx & TLS Setup Completed Successfully! ==="
echo "Test commands:"
echo "  curl -k https://taskops.local"
echo "  curl -k https://status.local"
echo "  curl -k https://taskops.local/api/todos"
echo "  curl -I http://taskops.local (to verify HTTP -> HTTPS 301 redirect)"
