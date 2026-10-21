# Dijalankan di server LB-SB-1 lewat SSM (deploy-lb-sb-1.yml). Workflow menaruh
# variabel B64_BUNDLE (tar.gz berisi docker-compose.yml dan nginx/conf.d/) di
# atas skrip ini. Aman diulang.
#
# 1. Sertifikat Let's Encrypt belum ada (deploy pertama): nginx dinyalakan
#    dengan 00-global.conf + http.conf saja (port 80), lalu certbot (container
#    sekali pakai, webroot /var/www/certbot) menerbitkan sertifikat.
# 2. Config lengkap ditulis ke staging/ dan diuji `nginx -t`. Hanya kalau lolos,
#    conf.d/ diganti dan proxy dibuat ulang. Kalau ditolak, proxy yang sedang
#    jalan tidak disentuh.
# 3. Timer systemd perpanjangan sertifikat dipasang/diperbarui.
set -euo pipefail

BASE=/opt/apps/nginx-reverse-proxy
# Domain yang sertifikatnya diterbitkan otomatis. Tambah situs = tambah domain
# di sini, server block port 80 di http.conf, dan file 443 di conf.d/.
DOMAINS=(wezy.dazytech.web.id)
CERTBOT_IMAGE=certbot/certbot
DOCKER=$(command -v docker)

mkdir -p "$BASE/nginx/conf.d" /etc/letsencrypt /var/www/certbot
cd "$BASE"

rm -rf incoming && mkdir incoming
echo "$B64_BUNDLE" | base64 -d | tar -xzf - -C incoming
cp incoming/docker-compose.yml docker-compose.yml

docker network inspect web-network >/dev/null 2>&1 || docker network create web-network
docker compose pull --quiet
docker pull --quiet "$CERTBOT_IMAGE" >/dev/null

# nginx_test <folder>: uji config di container sekali pakai (mount & network sama
# dengan proxy aslinya).
nginx_test() {
    docker run --rm --network web-network \
        -v "$BASE/$1:/etc/nginx/conf.d:ro" \
        -v /etc/letsencrypt:/etc/letsencrypt:ro \
        -v /var/www/certbot:/var/www/certbot:ro \
        nginx:alpine nginx -t
}

# apply <folder>: conf.d disamakan persis dengan folder itu (di server ini
# conf.d sepenuhnya milik repo), lalu proxy dibuat ulang.
apply() {
    # Container lama yang tidak dibuat compose di $BASE (manual, atau dari folder
    # lain) bentrok nama dengan container compose: hapus supaya bisa diambil alih.
    local owner
    owner=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' \
        nginx-reverse-proxy 2>/dev/null || echo none)
    if [ "$owner" != none ] && [ "$owner" != "$BASE" ]; then
        echo "container nginx-reverse-proxy lama bukan milik $BASE ($owner): dihapus"
        docker rm -f nginx-reverse-proxy >/dev/null
    fi
    rm -f nginx/conf.d/*
    cp "$1"/* nginx/conf.d/
    docker compose up -d --force-recreate
    sleep 2
}

# Pastikan http://<domain>/.well-known/acme-challenge/ sampai ke nginx INI sebelum
# memanggil Let's Encrypt: validasi gagal dibatasi 5x/jam per domain.
check_acme() {
    local token got dir=/var/www/certbot/.well-known/acme-challenge
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    mkdir -p "$dir"
    echo "$token" > "$dir/$token"
    got=$(curl -fsS --max-time 10 "http://$1/.well-known/acme-challenge/$token" 2>&1 || true)
    rm -f "${dir:?}/$token"
    if [ "$got" != "$token" ]; then
        echo "ERROR: http://$1/.well-known/acme-challenge/ tidak sampai ke server ini (${got:-tanpa jawaban})."
        echo "Cek DNS A record $1 -> IP publik server ini, dan security group membuka port 80 & 443."
        return 1
    fi
}

# --- 1. Sertifikat pertama ---
missing=()
for d in "${DOMAINS[@]}"; do
    [ -s "/etc/letsencrypt/live/$d/fullchain.pem" ] || missing+=("$d")
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "== Sertifikat belum ada: ${missing[*]}. nginx dinyalakan port 80 saja untuk certbot."
    rm -rf staging && mkdir staging
    cp incoming/nginx/conf.d/00-global.conf incoming/nginx/conf.d/http.conf staging/
    if ! nginx_test staging; then
        echo "ERROR: config port 80 ditolak nginx -t. Proxy lama tetap berjalan."
        exit 1
    fi
    apply staging
    for d in "${missing[@]}"; do
        check_acme "$d"
        docker run --rm \
            -v /etc/letsencrypt:/etc/letsencrypt \
            -v /var/www/certbot:/var/www/certbot \
            "$CERTBOT_IMAGE" certonly --webroot -w /var/www/certbot -d "$d" \
            --non-interactive --agree-tos --register-unsafely-without-email
    done
fi

# --- 2. Config lengkap ---
echo "== Config lengkap"
rm -rf staging && mkdir staging
cp incoming/nginx/conf.d/* staging/
if ! nginx_test staging; then
    echo "ERROR: config ditolak nginx -t. Proxy yang sedang jalan tidak disentuh; perbaiki config lalu deploy ulang."
    exit 1
fi
apply staging
docker compose ps

# --- 3. Perpanjangan sertifikat ---
# certbot di container (tidak perlu dipasang di host). ExecStopPost selalu jalan,
# juga saat ada sertifikat lain yang gagal diperpanjang: nginx membaca
# sertifikat hanya saat start/reload, dan reload tidak memutus koneksi.
cat > /etc/systemd/system/nginx-cert-renew.service <<EOF
[Unit]
Description=Perpanjang sertifikat Let's Encrypt lalu reload nginx-reverse-proxy
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=$DOCKER run --rm -v /etc/letsencrypt:/etc/letsencrypt -v /var/www/certbot:/var/www/certbot $CERTBOT_IMAGE renew --quiet
ExecStopPost=$DOCKER exec nginx-reverse-proxy nginx -s reload
EOF

cat > /etc/systemd/system/nginx-cert-renew.timer <<'EOF'
[Unit]
Description=Cek perpanjangan sertifikat Let's Encrypt 2x sehari

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now nginx-cert-renew.timer
echo "== Timer perpanjangan: $(systemctl is-active nginx-cert-renew.timer)"

# Jawaban lewat nginx server ini (bukan DNS). 502 = aplikasi belum jalan.
for d in "${DOMAINS[@]}"; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        --resolve "$d:443:127.0.0.1" "https://$d/api/health/" || true)
    echo "== https://$d/api/health/ -> HTTP $code"
    [ "$code" != 502 ] || echo "   502: aplikasi belum jalan (wezy-app: workflow Deploy Wezy (Next.js) di repo wezy)."
done
