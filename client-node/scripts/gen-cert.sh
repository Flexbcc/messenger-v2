#!/bin/bash
# Генерация self-signed TLS сертификата для nginx
# Для production используйте Let's Encrypt: https://certbot.eff.org/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SSL_DIR="$ROOT/config/nginx/ssl"

mkdir -p "$SSL_DIR"

# Читаем IP из .env если есть
VPS_IP="localhost"
if [ -f "$ROOT/.env" ]; then
    VPS_IP=$(grep "^HOME_NODE_PUBLIC_URL=" "$ROOT/.env" | sed 's|.*http[s]*://||;s|:.*||' || echo "localhost")
fi

echo "Генерация self-signed сертификата для IP: $VPS_IP"

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$SSL_DIR/server.key" \
    -out "$SSL_DIR/server.crt" \
    -subj "/CN=$VPS_IP/O=Messenger/C=RU" \
    -addext "subjectAltName=IP:$VPS_IP,IP:127.0.0.1,DNS:localhost"

chmod 600 "$SSL_DIR/server.key"
chmod 644 "$SSL_DIR/server.crt"

echo ""
echo "✓ Сертификат создан: $SSL_DIR/"
echo ""
echo "Отпечаток сертификата (для клиентов):"
openssl x509 -in "$SSL_DIR/server.crt" -noout -fingerprint -sha256 | sed 's/sha256 Fingerprint=//'
echo ""
echo "Для Let's Encrypt (если есть домен):"
echo "  certbot certonly --standalone -d yourdomain.com"
echo "  # Затем скопируйте cert.pem → server.crt, privkey.pem → server.key"
