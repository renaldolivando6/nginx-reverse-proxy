# Dijalankan di server Tencent lewat TAT (deploy-tencent-otp.yml). Workflow menaruh
# variabel B64_BUNDLE (tar.gz berisi docker-compose.yml dan nginx/conf.d/) di atas
# skrip ini. Aman diulang.
#
# Server ini melayani dua jenis domain:
# - otpnusantara.com: lewat Cloudflare, Cloudflare Origin Certificate (manual).
# - DOMAINS di bawah: langsung (tanpa Cloudflare), Let's Encrypt otomatis.
#
# 1. Sertifikat Let's Encrypt yang belum ada: nginx dinyalakan dengan semua config
#    KECUALI file yang memakai sertifikat itu (otpnusantara tetap jalan), lalu
#    certbot (container sekali pakai, webroot /var/www/certbot) menerbitkannya.
# 2. Config lengkap ditulis ke staging/ dan diuji `nginx -t`. Hanya kalau lolos,
#    conf.d/ diganti. Kalau ditolak, proxy yang sedang jalan tidak disentuh.
# 3. Timer systemd perpanjangan sertifikat dipasang/diperbarui.
#
# Perubahan config saja diterapkan dengan `nginx -s reload` (tanpa memutus
# koneksi); container hanya dibuat ulang bila docker-compose.yml berubah.
set -euo pipefail

BASE=/opt/apps/nginx-reverse-proxy
# Domain Let's Encrypt. Tambah situs = tambah domain di sini, file port 80
# (<situs>-http.conf) dan file 443 (<situs>.conf) di nginx/conf.d/.
DOMAINS=(skytastore.dazytech.web.id)
CERTBOT_IMAGE=certbot/certbot
DOCKER=$(command -v docker)

if [ ! -s /etc/ssl/otpnusantara/origin.pem ] || [ ! -s /etc/ssl/otpnusantara/origin.key ]; then
    echo "ERROR: Cloudflare Origin Certificate belum dipasang di /etc/ssl/otpnusantara (origin.pem, origin.key)."
    echo "Lihat servers/tencent-otp/README.md di repo nginx-reverse-proxy."
    exit 1
fi

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
        -v /etc/ssl/otpnusantara:/etc/ssl/otpnusantara:ro \
        -v /etc/letsencrypt:/etc/letsencrypt:ro \
        -v /var/www/certbot:/var/www/certbot:ro \
        nginx:alpine nginx -t
}

# apply <folder>: conf.d disamakan persis dengan folder itu (di server ini conf.d
# sepenuhnya milik repo). Container dibuat ulang hanya bila compose berubah;
# selain itu cukup reload.
apply() {
    local before after
    rm -f nginx/conf.d/*
    cp "$1"/* nginx/conf.d/
    before=$(docker inspect -f '{{.Id}}' nginx-reverse-proxy 2>/dev/null || true)
    docker compose up -d
    after=$(docker inspect -f '{{.Id}}' nginx-reverse-proxy 2>/dev/null || true)
    if [ -n "$before" ] && [ "$before" = "$after" ]; then
        docker exec nginx-reverse-proxy nginx -s reload
    fi
    sleep 2
}

# Pastikan domain memang sampai ke nginx INI sebelum memanggil Let's Encrypt
# sungguhan (validasi gagal dibatasi 5x/jam per domain):
# - DNS A record = IP publik server (metadata Tencent).
# - nginx lokal menyajikan file acme-challenge.
# - certbot --dry-run (server staging Let's Encrypt, batasnya terpisah) memvalidasi
#   dari internet: membuktikan firewall Lighthouse membuka port 80. Tidak bergantung
#   pada akses server ke IP publiknya sendiri (hairpin), yang tidak tersedia di sini.
check_domain() {
    local d=$1 public dns token got dir=/var/www/certbot/.well-known/acme-challenge
    public=$(curl -fsS --max-time 5 http://metadata.tencentyun.com/latest/meta-data/public-ipv4 || true)
    dns=$(getent ahostsv4 "$d" | awk 'NR==1 {print $1}' || true)
    if [ -n "$public" ] && [ "$dns" != "$public" ]; then
        echo "ERROR: DNS $d -> ${dns:-tidak ada}, seharusnya $public (A record di panel DNS domain)."
        return 1
    fi
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    mkdir -p "$dir"
    echo "$token" > "$dir/$token"
    got=$(curl -fsS --max-time 10 --resolve "$d:80:127.0.0.1" "http://$d/.well-known/acme-challenge/$token" 2>&1 || true)
    rm -f "${dir:?}/$token"
    if [ "$got" != "$token" ]; then
        echo "ERROR: nginx lokal tidak menyajikan acme-challenge untuk $d (${got:-tanpa jawaban}). Cek ${d%%.*}-http.conf."
        return 1
    fi
    if ! docker run --rm \
        -v /etc/letsencrypt:/etc/letsencrypt \
        -v /var/www/certbot:/var/www/certbot \
        "$CERTBOT_IMAGE" certonly --dry-run --webroot -w /var/www/certbot -d "$d" \
        --non-interactive --agree-tos --register-unsafely-without-email; then
        echo "ERROR: Let's Encrypt (dry-run) tidak bisa menjangkau http://$d/.well-known/acme-challenge/."
        echo "Paling mungkin firewall Lighthouse: buka TCP 80 dan 443 untuk 0.0.0.0/0 (console Tencent > Lighthouse > instance > Firewall)."
        return 1
    fi
}

# --- 1. Sertifikat pertama ---
missing=()
for d in "${DOMAINS[@]}"; do
    [ -s "/etc/letsencrypt/live/$d/fullchain.pem" ] || missing+=("$d")
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "== Sertifikat belum ada: ${missing[*]}. Config tanpa blok 443-nya dinyalakan dulu untuk certbot."
    rm -rf staging && mkdir staging
    for f in incoming/nginx/conf.d/*; do
        skip=0
        for d in "${missing[@]}"; do
            if grep -q "/etc/letsencrypt/live/$d/" "$f"; then skip=1; fi
        done
        [ "$skip" = 1 ] || cp "$f" staging/
    done
    if ! nginx_test staging; then
        echo "ERROR: config tahap sertifikat ditolak nginx -t. Proxy lama tetap berjalan."
        exit 1
    fi
    apply staging
    for d in "${missing[@]}"; do
        check_domain "$d"
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
# juga saat ada sertifikat yang gagal diperpanjang: nginx membaca sertifikat
# hanya saat start/reload, dan reload tidak memutus koneksi.
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
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "otpnusantara.com:443:127.0.0.1" "https://otpnusantara.com/up" || true)
echo "== https://otpnusantara.com/up -> HTTP $code"
for d in "${DOMAINS[@]}"; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        --resolve "$d:443:127.0.0.1" "https://$d/up" || true)
    echo "== https://$d/up -> HTTP $code"
    [ "$code" != 502 ] || echo "   502: aplikasi belum jalan (skyta-app: workflow Deploy Tencent (TAT) di repo skyta-store)."
done
