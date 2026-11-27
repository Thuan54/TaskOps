#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/openssl.cnf"

# Target directory specified in requirements: /etc/ssl/taskops/
DEFAULT_DEST_DIR="/etc/ssl/taskops"
DEST_DIR="${DEFAULT_DEST_DIR}"
INSTALL_TO_SYSTEM_TRUST=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate self-signed Root CA and TaskOps Server TLS Certificate with SAN.

Options:
  -d, --dest DIR        Destination directory (default: /etc/ssl/taskops)
  -t, --trust           Install CA to system trust store (requires root)
  -h, --help            Show this help message

Output files:
  ca.key                Root CA private key (0600)
  ca.crt                Root CA certificate (0644)
  taskops.key           Server private key (0600 / 0640)
  taskops.csr           Server CSR
  taskops.crt           Server certificate signed by CA (0644)
  taskops.bundle.crt    Fullchain bundle (Server cert + CA cert) (0644)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dest)
            DEST_DIR="$2"
            shift 2
            ;;
        -t|--trust)
            INSTALL_TO_SYSTEM_TRUST=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Error: OpenSSL config file not found at ${CONFIG_FILE}" >&2
    exit 1
fi

echo "=== TaskOps TLS Certificate Generator ==="
echo "Target directory: ${DEST_DIR}"

# Check if target requires root privileges
if [[ ! -w "$(dirname "${DEST_DIR}")" ]] && [[ ! -d "${DEST_DIR}" ]] && [[ $EUID -ne 0 ]]; then
    echo "Notice: Non-root user detected. If writing to ${DEST_DIR} fails, run with sudo or specify -d <dir>."
fi

mkdir -p "${DEST_DIR}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "[1/5] Generating Root CA private key and certificate..."
openssl req -x509 -new -nodes \
    -newkey rsa:4096 \
    -keyout "${TMP_DIR}/ca.key" \
    -out "${TMP_DIR}/ca.crt" \
    -days 3650 \
    -config "${CONFIG_FILE}" \
    -extensions v3_ca \
    -subj "/C=VN/ST=HoChiMinh/L=HoChiMinh/O=TaskOps Project/OU=DevOps Security/CN=TaskOps Root CA"

echo "[2/5] Generating Server private key and CSR..."
openssl req -new -nodes \
    -newkey rsa:2048 \
    -keyout "${TMP_DIR}/taskops.key" \
    -out "${TMP_DIR}/taskops.csr" \
    -config "${CONFIG_FILE}" \
    -subj "/C=VN/ST=HoChiMinh/L=HoChiMinh/O=TaskOps Project/OU=DevOps/CN=taskops.local"

echo "[3/5] Signing Server certificate with Root CA (SAN enabled)..."
openssl x509 -req \
    -in "${TMP_DIR}/taskops.csr" \
    -CA "${TMP_DIR}/ca.crt" \
    -CAkey "${TMP_DIR}/ca.key" \
    -CAcreateserial \
    -out "${TMP_DIR}/taskops.crt" \
    -days 365 \
    -extfile "${CONFIG_FILE}" \
    -extensions v3_server

echo "[4/5] Creating certificate bundle (fullchain)..."
cat "${TMP_DIR}/taskops.crt" "${TMP_DIR}/ca.crt" > "${TMP_DIR}/taskops.bundle.crt"

echo "[5/5] Installing certificates and setting secure permissions..."
cp -f "${TMP_DIR}/ca.key" "${DEST_DIR}/ca.key"
cp -f "${TMP_DIR}/ca.crt" "${DEST_DIR}/ca.crt"
cp -f "${TMP_DIR}/taskops.key" "${DEST_DIR}/taskops.key"
cp -f "${TMP_DIR}/taskops.csr" "${DEST_DIR}/taskops.csr"
cp -f "${TMP_DIR}/taskops.crt" "${DEST_DIR}/taskops.crt"
cp -f "${TMP_DIR}/taskops.bundle.crt" "${DEST_DIR}/taskops.bundle.crt"

# Set strict permissions
chmod 0755 "${DEST_DIR}"
chmod 0600 "${DEST_DIR}/ca.key" "${DEST_DIR}/taskops.key"
chmod 0644 "${DEST_DIR}/ca.crt" "${DEST_DIR}/taskops.crt" "${DEST_DIR}/taskops.bundle.crt" "${DEST_DIR}/taskops.csr"

# If www-data group exists and running as root, make server key readable by web server
if [[ $EUID -eq 0 ]] && getent group www-data >/dev/null 2>&1; then
    chgrp www-data "${DEST_DIR}/taskops.key" 2>/dev/null || true
    chmod 0640 "${DEST_DIR}/taskops.key" || true
fi

echo "Verifying server certificate against CA:"
openssl verify -CAfile "${DEST_DIR}/ca.crt" "${DEST_DIR}/taskops.crt"

echo ""
echo "Certificate details:"
openssl x509 -in "${DEST_DIR}/taskops.crt" -noout -subject -issuer -dates
echo "Subject Alternative Names:"
openssl x509 -in "${DEST_DIR}/taskops.crt" -noout -ext subjectAltName

if [[ "${INSTALL_TO_SYSTEM_TRUST}" == "true" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "Warning: System trust store installation requires root privileges. Skipping." >&2
    else
        echo "Adding CA to system trust store (/usr/local/share/ca-certificates/)..."
        cp -f "${DEST_DIR}/ca.crt" /usr/local/share/ca-certificates/taskops-ca.crt
        update-ca-certificates
        echo "Root CA installed into system trust store successfully."
    fi
fi

echo ""
echo "All certificates successfully generated and stored at: ${DEST_DIR}"
