# Reverse proxy server Tencent (otpnusantara.com)

Server: Tencent Lighthouse Jakarta, instance `lhins-jf50zxos`, IP `43.173.53.33`.
Terpisah dari server AWS (WEB_LINUX: `nginx/` di root repo + `deploy-web-linux.yml`;
LB-SB-1: `servers/lb-sb-1/`).

## Isi folder

| File | Fungsi |
|---|---|
| `docker-compose.yml` | container `nginx-reverse-proxy` (port 80/443, network `web-network`) |
| `nginx/conf.d/00-global.conf` | IP asli dari Cloudflare, format log, pembatas request |
| `nginx/conf.d/otpnusantara.conf` | domain otpnusantara.com, upstream `otp-app` |
| `nginx/conf.d/otp-proxy.inc` | header dan buffer proxy ke aplikasi |
| `deploy/apply.sh` | dijalankan di server lewat TAT: uji `nginx -t`, lalu terapkan |

## Cloudflare (wajib)

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

## Deploy

Actions > **Deploy Nginx Reverse Proxy (Tencent TAT - otpnusantara.com)**. Jalankan setelah
OTP Nusantara ter-deploy (proxy tetap bisa start walau `otp-app` belum ada, tetapi situs
baru bisa dibuka setelah app jalan).

GitHub Secrets di repo ini: `TENCENTCLOUD_SECRET_ID`, `TENCENTCLOUD_SECRET_KEY`,
`TENCENT_REGION` (`ap-jakarta`), `TENCENT_INSTANCE_ID_OTP` (`lhins-jf50zxos`).
