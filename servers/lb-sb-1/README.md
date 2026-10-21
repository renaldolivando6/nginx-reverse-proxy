# Reverse proxy server AWS LB-SB-1 (wezy.dazytech.web.id)

Server AWS khusus Wezy: hanya `nginx-reverse-proxy` dan `wezy-app` (repo `wezy`).
Dulu server test (tebu-test, dazy-test; secret lama `SSM_INSTANCE_ID_LINUX_TEST`).
Terpisah dari server AWS utama WEB_LINUX (config di `nginx/` root repo, `deploy-web-linux.yml`).

## Isi folder

| File | Fungsi |
|---|---|
| `docker-compose.yml` | container `nginx-reverse-proxy` (port 80/443, network `web-network`, log dirotasi) |
| `nginx/conf.d/00-global.conf` | format log, resolver DNS Docker |
| `nginx/conf.d/http.conf` | port 80: acme-challenge certbot, redirect ke HTTPS, host asing ditutup |
| `nginx/conf.d/wezy.conf` | port 443: `wezy.dazytech.web.id` -> `wezy-app:3000`, SNI asing ditolak |
| `deploy/apply.sh` | dijalankan di server lewat SSM: terbit sertifikat (bila belum ada), uji `nginx -t`, terapkan, pasang timer perpanjangan |

Upstream dipanggil lewat variabel + resolver Docker, jadi nginx tetap start walau
`wezy-app` belum ada (jawab 502), dan container app yang dibuat ulang langsung
terbaca tanpa reload.

## Deploy pertama

1. **Bersihkan container lama** (sesi SSM ke LB-SB-1). Cek dulu volume yang dipakai,
   karena datanya ikut hilang kalau volumenya dihapus:

   ```bash
   sudo docker inspect -f '{{.Name}}: {{range .Mounts}}{{.Type}} {{.Name}}{{.Source}} -> {{.Destination}}; {{end}}' dazytech-app tebu-app tebu-redis
   sudo docker rm -f dazytech-app tebu-app tebu-redis
   sudo docker image prune -a -f
   sudo docker volume ls          # hapus yang milik tebu/dazytech: sudo docker volume rm <nama>
   sudo crontab -l; ls /etc/cron.d   # buang cron yang memanggil tebu-app (mis. schedule:run)
   ```

   Proxy lama dibiarkan; workflow di bawah mengganti config-nya.
2. **DNS**: A record `wezy.dazytech.web.id` -> IP publik LB-SB-1 (pakai Elastic IP supaya
   tidak berubah saat instance di-stop). Security group membuka port 80 dan 443.
3. **GitHub Secrets** repo ini: `SSM_INSTANCE_ID_LB_SB_1` (instance ID LB-SB-1). Kredensial
   `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` dipakai bersama `deploy-web-linux.yml`;
   IAM user-nya harus boleh `ssm:SendCommand` ke instance ini.
4. Actions > **Deploy Nginx Reverse Proxy (LB-SB-1 - wezy.dazytech.web.id)**. Deploy pertama
   menerbitkan sertifikat Let's Encrypt lebih dulu. Sebelum memanggil Let's Encrypt, skrip
   memastikan `http://wezy.dazytech.web.id/.well-known/acme-challenge/` memang sampai ke
   server ini; kalau DNS belum mengarah ke sini, deploy berhenti dengan pesan jelas.
   Akhir output: `/api/health/ -> HTTP 502` = normal sebelum Wezy dideploy.
5. Repo `wezy`: Actions > **Deploy Wezy (Next.js)** (secret `SSM_INSTANCE_ID_LB_SB_1`
   juga diisi di repo itu).

## Sertifikat

- Diterbitkan dan diperpanjang `certbot/certbot` di container sekali pakai (tidak perlu
  certbot di host), metode webroot `/var/www/certbot`.
- Timer systemd `nginx-cert-renew.timer` (2x sehari) menjalankan `certbot renew`, lalu
  selalu `nginx -s reload` (tanpa memutus koneksi).
- Cek: `systemctl list-timers nginx-cert-renew.timer`, `journalctl -u nginx-cert-renew -n 20`.
  Uji jalur perpanjangan tanpa menyentuh sertifikat:
  `sudo docker run --rm -v /etc/letsencrypt:/etc/letsencrypt -v /var/www/certbot:/var/www/certbot certbot/certbot renew --dry-run`.

## Menambah situs

Tambah domain di `DOMAINS` (`deploy/apply.sh`), server block port 80 di `http.conf`, dan
file `.conf` baru untuk port 443. Semua file di `nginx/conf.d/` ikut terkirim; isi
`conf.d` di server disamakan persis dengan folder ini.
