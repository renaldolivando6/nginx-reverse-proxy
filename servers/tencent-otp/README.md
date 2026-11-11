# Reverse proxy server Tencent (otpnusantara.com, cleogames.id)

Server: Tencent Lighthouse Jakarta, instance `lhins-jf50zxos`, IP `43.173.53.33`.
Terpisah dari server AWS (WEB_LINUX: `nginx/` di root repo + `deploy-web-linux.yml`;
LB-SB-1: `servers/lb-sb-1/`).

Semua domain di server ini lewat Cloudflare (awan oranye) dengan SSL/TLS **Full (strict)**
dan Cloudflare Origin Certificate. Tidak ada Let's Encrypt dan tidak ada domain yang
menjangkau server langsung.

| Domain | Sertifikat | Upstream | Repo aplikasi |
|---|---|---|---|
| `otpnusantara.com` | `/etc/ssl/otpnusantara/` | `otp-app` | otp-nusantara |
| `cleogames.id` | `/etc/ssl/cleogames/` | `cleo-app` | cleogames.id |

## Isi folder

| File | Fungsi |
|---|---|
| `docker-compose.yml` | container `nginx-reverse-proxy` (port 80/443, network `web-network`) |
| `nginx/conf.d/00-global.conf` | resolver Docker, IP asli dari Cloudflare, `$origin_allowed`, format log, pembatas request |
| `nginx/conf.d/01-default.conf` | host tak dikenal: port 80 ditutup, port 443 ditolak saat handshake |
| `nginx/conf.d/otpnusantara.conf` | otpnusantara.com, upstream `otp-app` |
| `nginx/conf.d/otp-proxy.inc` | header dan buffer proxy ke otp-app |
| `nginx/conf.d/cleogames.conf` | cleogames.id, upstream `cleo-app` |
| `nginx/conf.d/cleo-proxy.inc` | header dan buffer proxy ke cleo-app |
| `deploy/apply.sh` | dijalankan di server lewat TAT: cek sertifikat, uji `nginx -t`, terapkan |

## Firewall Lighthouse

Console Tencent > Lighthouse > instance > **Firewall**: TCP **80** dan **443** hanya dari
rentang IPv4 Cloudflare (https://www.cloudflare.com/ips-v4/, satu aturan per rentang,
port `80,443`). Tidak ada aturan 80/443 dari `0.0.0.0/0` (aturan TEMP untuk
skytastore.dazytech.web.id sudah dihapus 11 November 2026). Port 22 tetap hanya untuk IP kantor.

Lapisan kedua: server block setiap situs menolak koneksi yang bukan dari rentang
Cloudflare atau dari server ini sendiri (`$origin_allowed` di `00-global.conf`), dan
`01-default.conf` tidak mengirim sertifikat apa pun ke akses lewat IP. Jadi WAF Cloudflare
tidak bisa dilewati lewat IP server walau firewall suatu saat dilonggarkan.

## Cloudflare (berlaku untuk setiap domain)

Contoh untuk cleogames.id; otpnusantara.com sudah dengan pola yang sama.

1. **Add a site** `cleogames.id` (paket Free). Cloudflare memberi dua nameserver; ganti
   nameserver domain di registrar (panel tempat domain dibeli) ke dua nameserver itu.
   Status zona berubah **Active** setelah propagasi (domain `.id` bisa beberapa jam).
2. **DNS**: hapus record bawaan registrar yang ikut ter-import (mis. A ke halaman parkir),
   lalu buat:
   - `A  cleogames.id  43.173.53.33`  proxy **aktif** (awan oranye)
   - `CNAME  www  cleogames.id`  proxy **aktif**
3. **SSL/TLS > Overview**: mode **Full (strict)**. **Edge Certificates**: Always Use HTTPS
   aktif, Minimum TLS 1.2.
4. **SSL/TLS > Origin Server > Create Certificate** (RSA, hostname `cleogames.id` dan
   `*.cleogames.id`, 15 tahun). Pasang di server lewat OrcaTerm:

   ```bash
   sudo mkdir -p /etc/ssl/cleogames && sudo chmod 700 /etc/ssl/cleogames
   sudo nano /etc/ssl/cleogames/origin.pem   # tempel "Origin Certificate"
   sudo nano /etc/ssl/cleogames/origin.key   # tempel "Private Key"
   sudo chmod 600 /etc/ssl/cleogames/origin.key
   ```

   Sertifikat ini hanya dipercaya Cloudflare. Kalau proxy Cloudflare dimatikan, browser
   menolak sertifikatnya.
5. **Security > Settings: Bot Fight Mode mati.** Di paket Free, Bot Fight Mode tidak bisa
   dikecualikan per path (aturan Skip WAF tidak berlaku untuknya), jadi webhook supplier
   dan gateway pembayaran (`/api/webhooks/...`) akan ditantang captcha.
6. **Speed > Optimization**: Rocket Loader **mati** (menulis ulang tag script; bentrok dengan
   CSP nonce dan Inertia). **Scrape Shield**: Email Address Obfuscation **mati** (menyisipkan
   script yang diblokir CSP).
7. Rentang IP Cloudflare tercatat dua kali di `00-global.conf` (`set_real_ip_from` dan
   `geo $origin_allowed`) dan sekali di firewall Lighthouse: perbarui ketiganya bersamaan.

## Deploy

Actions > **Deploy Nginx Reverse Proxy (Tencent TAT - otpnusantara.com, cleogames.id)**.
Semua file di `nginx/conf.d/` dikirim sebagai satu bundel; isi `conf.d` di server
disamakan persis dengan folder ini. Perubahan config saja diterapkan dengan reload
(tanpa memutus koneksi); container dibuat ulang hanya bila `docker-compose.yml` berubah.
Deploy ditolak bila salah satu Origin Certificate belum dipasang. Akhir output:
`/up -> HTTP 502` untuk sebuah domain = aplikasinya belum jalan.

GitHub Secrets di repo ini: `TENCENTCLOUD_SECRET_ID`, `TENCENTCLOUD_SECRET_KEY`,
`TENCENT_REGION` (`ap-jakarta`), `TENCENT_INSTANCE_ID_OTP` (`lhins-jf50zxos`).

## Menambah situs

Ikuti pola `cleogames.conf` (termasuk penjaga `$origin_allowed`) dan `cleo-proxy.inc`,
tambah zona `limit_req_zone` di `00-global.conf`, mount `/etc/ssl/<situs>` di
`docker-compose.yml`, lalu tambah folder sertifikat dan domain di `CERT_DIRS` dan
`DOMAINS` (`deploy/apply.sh`).
