# Pengaturan proxy ke skyta-app. Berekstensi .inc supaya tidak ter-include otomatis
# oleh nginx.conf (yang hanya membaca conf.d/*.conf); dipakai lewat `include`.
#
# X-Forwarded-For diisi IP koneksi SAJA ($remote_addr), bukan rantai dari klien,
# supaya tidak bisa dipalsukan. Laravel mempercayai header ini hanya dari subnet
# web-network (TRUSTED_PROXIES).
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $remote_addr;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Port  443;

# Laravel/Inertia mengirim header besar (cookie session + flash, CSP). Buffer
# bawaan nginx (4k/8k) kepenuhan -> 502 "upstream sent too big header".
proxy_buffer_size 16k;
proxy_buffers 8 16k;
proxy_busy_buffers_size 32k;
