# Dijalankan di server Tencent lewat TAT (deploy-tencent-otp.yml). Workflow menaruh
# variabel B64_BUNDLE (tar.gz berisi docker-compose.yml dan nginx/conf.d/) di atas
# skrip ini. Aman diulang.
#
# Semua domain di server ini lewat Cloudflare (awan oranye) dengan Cloudflare Origin
# Certificate yang dipasang manual di /etc/ssl/<situs>/ (README).
#
# 1. Config ditulis ke staging/ dan diuji `nginx -t`. Hanya kalau lolos, conf.d/
#    diganti. Kalau ditolak, proxy yang sedang jalan tidak disentuh.
# 2. Perubahan config saja diterapkan dengan `nginx -s reload` (tanpa memutus
#    koneksi); container hanya dibuat ulang bila docker-compose.yml berubah.
set -euo pipefail

BASE=/opt/apps/nginx-reverse-proxy
# Tambah situs = tambah folder sertifikat di sini, mount di docker-compose.yml,
# dan domainnya di DOMAINS (cek akhir).
CERT_DIRS=(/etc/ssl/otpnusantara /etc/ssl/cleogames)
DOMAINS=(otpnusantara.com cleogames.id)

for dir in "${CERT_DIRS[@]}"; do
    if [ ! -s "$dir/origin.pem" ] || [ ! -s "$dir/origin.key" ]; then
        echo "ERROR: Cloudflare Origin Certificate belum dipasang di $dir (origin.pem, origin.key)."
        echo "Lihat servers/tencent-otp/README.md di repo nginx-reverse-proxy."
        exit 1
    fi
done

mkdir -p "$BASE/nginx/conf.d"
cd "$BASE"

rm -rf incoming && mkdir incoming
echo "$B64_BUNDLE" | base64 -d | tar -xzf - -C incoming
cp incoming/docker-compose.yml docker-compose.yml

docker network inspect web-network >/dev/null 2>&1 || docker network create web-network
docker compose pull --quiet

# Uji config di container sekali pakai (mount & network sama dengan proxy aslinya).
cert_mounts=()
for dir in "${CERT_DIRS[@]}"; do
    cert_mounts+=(-v "$dir:$dir:ro")
done

rm -rf staging && mkdir staging
cp incoming/nginx/conf.d/* staging/
if ! docker run --rm --network web-network \
    -v "$BASE/staging:/etc/nginx/conf.d:ro" "${cert_mounts[@]}" \
    nginx:alpine nginx -t; then
    echo "ERROR: config ditolak nginx -t. Proxy yang sedang jalan tidak disentuh; perbaiki config lalu deploy ulang."
    exit 1
fi

# conf.d disamakan persis dengan repo (di server ini conf.d sepenuhnya milik repo).
rm -f nginx/conf.d/*
cp staging/* nginx/conf.d/
before=$(docker inspect -f '{{.Id}}' nginx-reverse-proxy 2>/dev/null || true)
docker compose up -d
after=$(docker inspect -f '{{.Id}}' nginx-reverse-proxy 2>/dev/null || true)
if [ -n "$before" ] && [ "$before" = "$after" ]; then
    docker exec nginx-reverse-proxy nginx -s reload
fi
sleep 2
docker compose ps

# Sisa skytastore.dazytech.web.id (Let's Encrypt): timer, sertifikat, dan image certbot
# sudah dihapus 11 November 2026. Dua folder kosong dibiarkan selama container lama masih
# me-mount-nya; dihapus di sini begitu container memakai docker-compose.yml tanpa mount itu.
if ! docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' nginx-reverse-proxy | grep -qE '/etc/letsencrypt|/var/www/certbot'; then
    rmdir /etc/letsencrypt /var/www/certbot 2>/dev/null || true
fi

# Jawaban lewat nginx server ini (bukan Cloudflare). 502 = aplikasi belum jalan.
for d in "${DOMAINS[@]}"; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        --resolve "$d:443:127.0.0.1" "https://$d/up" || true)
    echo "== https://$d/up -> HTTP $code"
done
