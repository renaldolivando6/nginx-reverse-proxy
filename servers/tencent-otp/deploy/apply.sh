# Dijalankan di server Tencent lewat TAT (deploy-tencent-otp.yml). Workflow menaruh
# variabel B64_COMPOSE, B64_GLOBAL, B64_SITE, B64_PROXY di atas skrip ini.
#
# Config ditulis ke staging/ lalu diuji `nginx -t` (container sekali pakai, mount
# sama). Hanya kalau lolos, conf.d/ diganti dan proxy dibuat ulang. Kalau ditolak,
# proxy yang sedang jalan tidak disentuh.
set -euo pipefail

BASE=/opt/apps/nginx-reverse-proxy

if [ ! -s /etc/ssl/otpnusantara/origin.pem ] || [ ! -s /etc/ssl/otpnusantara/origin.key ]; then
    echo "ERROR: Cloudflare Origin Certificate belum dipasang di /etc/ssl/otpnusantara (origin.pem, origin.key)."
    echo "Lihat servers/tencent-otp/README.md di repo nginx-reverse-proxy."
    exit 1
fi

mkdir -p "$BASE/nginx/conf.d" /var/www/certbot
cd "$BASE"

rm -rf staging && mkdir -p staging
echo "$B64_COMPOSE" | base64 -d > docker-compose.yml
echo "$B64_GLOBAL" | base64 -d > staging/00-global.conf
echo "$B64_SITE" | base64 -d > staging/otpnusantara.conf
echo "$B64_PROXY" | base64 -d > staging/otp-proxy.inc

docker network inspect web-network >/dev/null 2>&1 || docker network create web-network
docker compose pull --quiet

if ! docker run --rm --network web-network \
    -v "$BASE/staging:/etc/nginx/conf.d:ro" \
    -v /etc/ssl/otpnusantara:/etc/ssl/otpnusantara:ro \
    -v /var/www/certbot:/var/www/certbot:ro \
    nginx:alpine nginx -t; then
    echo "ERROR: config ditolak nginx -t. Proxy lama tetap berjalan; perbaiki config lalu deploy ulang."
    exit 1
fi

# Folder conf.d di server ini sepenuhnya milik repo: isinya disamakan persis.
rm -f nginx/conf.d/*
cp staging/* nginx/conf.d/
docker compose up -d --force-recreate
sleep 2
docker compose ps
