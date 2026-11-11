# Reverse proxy server Tencent (otpnusantara.com, skytastore.dazytech.web.id)

Server: Tencent Lighthouse Jakarta, instance `lhins-jf50zxos`, IP `43.173.53.33`.
Terpisah dari server AWS (WEB_LINUX: `nginx/` di root repo + `deploy-web-linux.yml`;
LB-SB-1: `servers/lb-sb-1/`).

| Domain | Jalur | Sertifikat | Upstream |
|---|---|---|---|
| `otpnusantara.com` | lewat Cloudflare (awan oranye) | Cloudflare Origin Certificate, manual | `otp-app` |
| `skytastore.dazytech.web.id` | langsung (DNS Dewaweb) | Let's Encrypt, otomatis | `skyta-app` |

## Isi folder

| File | Fungsi |
|---|---|
| `docker-compose.yml` | container `nginx-reverse-proxy` (port 80/443, network `web-network`) |
| `nginx/conf.d/00-global.conf` | resolver Docker, IP asli dari Cloudflare, `$origin_allowed`, format log, pembatas request |
| `nginx/conf.d/otpnusantara.conf` | otpnusantara.com (hanya menerima koneksi dari Cloudflare atau server ini), host asing ditutup |
| `nginx/conf.d/otp-proxy.inc` | header dan buffer proxy ke otp-app |
| `nginx/conf.d/skytastore-http.conf` | port 80 skytastore: acme-challenge certbot, redirect ke HTTPS |
| `nginx/conf.d/skytastore.conf` | port 443 skytastore, upstream `skyta-app` |
| `nginx/conf.d/skyta-proxy.inc` | header dan buffer proxy ke skyta-app |
| `deploy/apply.sh` | dijalankan di server lewat TAT: sertifikat, uji `nginx -t`, terapkan, timer perpanjangan |

## Firewall Lighthouse (wajib untuk skytastore)

Console Tencent > Lighthouse > instance > **Firewall**: TCP **80** dan **443** dari
`0.0.0.0/0`. Domain tanpa Cloudflare (dan Let's Encrypt) harus bisa menjangkau server
langsung. otpnusantara tetap terlindung: server block-nya menolak koneksi yang bukan dari
rentang IP Cloudflare atau dari server ini sendiri (`$origin_allowed` di `00-global.conf`),
jadi WAF Cloudflare tidak bisa dilewati lewat IP server. Port 22 tetap hanya untuk IP kantor.

## Cloudflare (otpnusantara.com)

1. DNS `otpnusantara.com` dan `www`: proxy **aktif** (awan oranye).
2. SSL/TLS > Overview: mode **Full (strict)**.
3. SSL/TLS > Origin Server > **Create Certificate** (RSA, hostname `otpnusantara.com` dan
   `*.otpnusantara.com`, 15 tahun). Pasang di server lewat OrcaTerm:

   ```bash
   sudo mkdir -p /etc/ssl/otpnusantara && sudo chmod 700 /etc/ssl/otpnusantara
   sudo nano /etc/ssl/otpnusantara/origin.pem   # tempel "Origin Certificate"
   sudo nano /etc/ssl/otpnusantara/origin.key   # tempel "Private Key"
   sudo chmod 600 /etc/ssl/otpnusantara/origin.key
   ```

   Sertifikat ini hanya dipercaya Cloudflare. Kalau proxy Cloudflare dimatikan, browser
   menolak sertifikatnya.
4. Security > WAF: kalau Bot Fight Mode aktif, buat aturan **Skip** untuk path
   `/api/webhooks/` supaya webhook HeroSMS tidak ditantang captcha.
5. Rentang IP Cloudflare (https://www.cloudflare.com/ips/) tercatat dua kali di
   `00-global.conf` (`set_real_ip_from` dan `geo $origin_allowed`): perbarui bersamaan.

## Sertifikat Let's Encrypt (skytastore)

- Deploy pertama: nginx dinyalakan dengan semua config **kecuali** `skytastore.conf`
  (otpnusantara tetap jalan), lalu certbot (container sekali pakai, webroot
  `/var/www/certbot`) menerbitkan sertifikat. Sebelumnya skrip memastikan DNS mengarah ke
  server ini dan menjalankan `certbot --dry-run` ke server staging Let's Encrypt (batasnya
  terpisah dari batas validasi gagal 5x/jam). Kalau dry-run gagal, hampir pasti firewall
  Lighthouse port 80 belum dibuka.
- Timer systemd `nginx-cert-renew.timer` (2x sehari) menjalankan `certbot renew`, lalu
  `nginx -s reload` (tanpa memutus koneksi).
- Cek: `systemctl list-timers nginx-cert-renew.timer`, `journalctl -u nginx-cert-renew -n 20`.

## Deploy

Actions > **Deploy Nginx Reverse Proxy (Tencent TAT - otpnusantara.com, skytastore)**.
Semua file di `nginx/conf.d/` dikirim sebagai satu bundel; isi `conf.d` di server
disamakan persis dengan folder ini. Perubahan config saja diterapkan dengan reload
(tanpa memutus koneksi); container dibuat ulang hanya bila `docker-compose.yml` berubah.
Akhir output: `/up -> HTTP 502` untuk skytastore = normal sebelum Skyta dideploy.

GitHub Secrets di repo ini: `TENCENTCLOUD_SECRET_ID`, `TENCENTCLOUD_SECRET_KEY`,
`TENCENT_REGION` (`ap-jakarta`), `TENCENT_INSTANCE_ID_OTP` (`lhins-jf50zxos`).

## Menambah situs

Tanpa Cloudflare: tambah domain di `DOMAINS` (`deploy/apply.sh`), file port 80
`<situs>-http.conf`, dan file 443 `<situs>.conf` yang memakai
`/etc/letsencrypt/live/<domain>/`. Lewat Cloudflare: ikuti pola `otpnusantara.conf`
(termasuk penjaga `$origin_allowed`).
