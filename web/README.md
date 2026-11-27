# Nhóm E — Nginx, Reverse Proxy & TLS Configuration

Tài liệu chi tiết về kiến trúc, cấu hình và quy trình triển khai cho hai nhiệm vụ:
- **E01**: Tạo self-signed CA bằng OpenSSL, sinh server certificate và lưu trữ tại `/etc/ssl/taskops/`.
- **E02**: Viết Nginx vhost cho `taskops.local`, `status.local`, phục vụ React static files, reverse proxy `/api/` và proxy headers, cấu hình HTTPS 443 và redirect HTTP sang HTTPS.

---

## 1. Cấu trúc thư mục (`web/`)

```
web/
├── nginx/
│   ├── snippets/
│   │   ├── ssl-params.conf          # TLSv1.2/1.3, cipher suites, session cache & timeout
│   │   ├── proxy-params.conf        # Header chuyển tiếp cho Reverse Proxy
│   │   └── security-headers.conf    # HSTS, X-Frame-Options, nosniff, Referrer-Policy
│   ├── taskops.local.conf           # Vhost cho taskops.local (React SPA + API Reverse Proxy)
│   ├── status.local.conf            # Vhost cho status.local (Trang trạng thái tĩnh)
│   └── todo.local.conf              # Symlink trỏ đến taskops.local.conf
├── tls/
│   ├── openssl.cnf                  # File cấu hình OpenSSL hỗ trợ SAN đa tên miền & IP
│   └── gen-ca.sh                    # Kịch bản sinh CA, Server certificate và phân quyền
├── static/
│   └── status/
│       └── index.html               # Giao diện tĩnh kiểm tra trạng thái dịch vụ TaskOps
├── setup-nginx.sh                   # Kịch bản tự động hóa toàn bộ quá trình cài đặt lên Nginx
└── README.md                        # Tài liệu hướng dẫn (file này)
```

---

## 2. Chi tiết kỹ thuật & Triển khai

### 2.1. Task E01 — OpenSSL Self-Signed CA & Server Certificate

#### Mục tiêu
Xây dựng một hạ tầng khóa công khai (PKI) nội bộ bằng OpenSSL:
1. Tạo Root Certificate Authority (CA) tự ký.
2. Tạo khóa riêng (private key) và yêu cầu ký chứng chỉ (CSR) cho server.
3. Ký chứng chỉ server bằng CA với các tên miền và địa chỉ IP thay thế (SAN - Subject Alternative Names).
4. Tạo gói chuỗi chứng chỉ đầy đủ (`bundle / fullchain`).
5. Lưu trữ và phân quyền nghiêm ngặt tại `/etc/ssl/taskops/`.

#### Cấu hình SAN (`web/tls/openssl.cnf`)
File `openssl.cnf` được thiết kế để một chứng chỉ server duy nhất có thể bảo vệ cả hai tên miền nội bộ và IP máy chủ:
```ini
[ alt_names ]
DNS.1   = taskops.local
DNS.2   = status.local
DNS.3   = todo.local
DNS.4   = localhost
IP.1    = 127.0.0.1
IP.2    = 192.168.56.10
```

#### Kịch bản sinh chứng chỉ (`web/tls/gen-ca.sh`)
Kịch bản tự động thực hiện 5 bước:
1. **Sinh Root CA**: Tạo `ca.key` (RSA 4096-bit) và `ca.crt` tự ký có thời hạn 3650 ngày (10 năm).
2. **Sinh Server Key & CSR**: Tạo `taskops.key` (RSA 2048-bit) và `taskops.csr` với Common Name `taskops.local`.
3. **Ký chứng chỉ server**: Ký CSR bằng `ca.crt` và `ca.key` kèm extension `v3_server` (chứa SAN và extendedKeyUsage `serverAuth`).
4. **Tạo chứng chỉ Bundle**: Ghép `taskops.crt` và `ca.crt` thành `taskops.bundle.crt` để trình duyệt/client có thể xác thực trọn vẹn chuỗi chứng chỉ.
5. **Phân quyền và bảo mật tại `/etc/ssl/taskops/`**:
   - Thư mục: `0755` (`drwxr-xr-x`)
   - Khóa bí mật (`ca.key`, `taskops.key`): `0600` (hoặc `0640 root:www-data`)
   - Chứng chỉ công khai (`ca.crt`, `taskops.crt`, `taskops.bundle.crt`): `0644` (`-rw-r--r--`)
   - Tùy chọn cờ `-t` hoặc `--trust` để tự động chép CA vào `/usr/local/share/ca-certificates/` và chạy `update-ca-certificates`.

---

### 2.2. Task E02 — Nginx Virtual Hosts, Reverse Proxy & TLS Redirection

#### A. Các Snippet dùng chung (`web/nginx/snippets/`)

* **`ssl-params.conf`**:
  * Giao thức: Giới hạn chỉ dùng `TLSv1.2` và `TLSv1.3` (loại bỏ SSLv3, TLS 1.0, TLS 1.1 đã lỗi thời).
  * Mã hóa: Cipher suite mạnh mẽ theo chuẩn Mozilla Intermediate:
    `ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384...`
  * Session Cache: `shared:SSL:10m` giúp tăng tốc độ bắt tay TLS (handshake) cho các kết nối lặp lại.
  * Tắt session tickets để duy trì tính chất Perfect Forward Secrecy (PFS).

* **`proxy-params.conf`**:
  * `proxy_http_version 1.1`: Bắt buộc cho kết nối keep-alive và WebSocket.
  * Chuyển tiếp các header nhận diện client thực tế:
    * `Host $host`
    * `X-Real-IP $remote_addr`
    * `X-Forwarded-For $proxy_add_x_forwarded_for`
    * `X-Forwarded-Proto $scheme` (cho phép backend biết request ban đầu là HTTPS)
    * `X-Forwarded-Port $server_port`
  * Hỗ trợ nâng cấp giao thức WebSocket (`Upgrade`, `Connection`).

* **`security-headers.conf`**:
  * `X-Frame-Options: SAMEORIGIN` (chống Clickjacking)
  * `X-Content-Type-Options: nosniff` (chống MIME sniffing)
  * `X-XSS-Protection: 1; mode=block`
  * `Strict-Transport-Security: max-age=31536000; includeSubDomains` (HSTS)
  * `Referrer-Policy: strict-origin-when-cross-origin`

---

#### B. Vhost `taskops.local` (`web/nginx/taskops.local.conf`)

1. **HTTP sang HTTPS Redirection (Port 80)**:
   ```nginx
   server {
       listen 80;
       listen [::]:80;
       server_name taskops.local;
       return 301 https://$host$request_uri;
   }
   ```
2. **HTTPS Server (Port 443 + HTTP/2)**:
   - Sử dụng chứng chỉ `/etc/ssl/taskops/taskops.bundle.crt` và khóa `/etc/ssl/taskops/taskops.key`.
   - **Static React Frontend**:
     - `root /var/www/taskops-app;`
     - Cấu hình định tuyến Single Page Application (SPA):
       ```nginx
       location / {
           try_files $uri $uri/ /index.html;
       }
       ```
     - Caching tối ưu cho tài nguyên tĩnh:
       ```nginx
       location ~* \.(?:css|js|jpg|jpeg|gif|png|ico|svg|woff|woff2|ttf|eot)$ {
           expires 30d;
           add_header Cache-Control "public, no-transform";
           try_files $uri =404;
       }
       ```
   - **Reverse Proxy `/api/`**:
     - Chuyển tiếp các request bắt đầu bằng `/api/` tới NodeJS Express app chạy tại `127.0.0.1:5000`:
       ```nginx
       location /api/ {
           proxy_pass http://127.0.0.1:5000;
           include /etc/nginx/snippets/proxy-params.conf;
       }
       ```

---

#### C. Vhost `status.local` (`web/nginx/status.local.conf`)

1. **HTTP sang HTTPS Redirection (Port 80)**: Chuyển hướng 301 về `https://status.local$request_uri`.
2. **HTTPS Server (Port 443 + HTTP/2)**:
   - Cung cấp trang tĩnh báo cáo tình trạng hệ thống từ `/var/www/taskops-status`.
   - `location / { try_files $uri $uri/ =404; }`.

---

## 3. Quy trình triển khai tự động (`web/setup-nginx.sh`)

Kịch bản `setup-nginx.sh` giúp thiết lập toàn bộ môi trường chỉ với một lệnh duy nhất:

```bash
sudo bash web/setup-nginx.sh
```

### Các bước script thực hiện:
1. Gọi `gen-ca.sh` để sinh chứng chỉ SSL và cài đặt vào `/etc/ssl/taskops/`, đồng thời thêm CA vào hệ thống.
2. Sao chép các snippet vào `/etc/nginx/snippets/`.
3. Sao chép và kích hoạt các vhost (`taskops.local.conf`, `status.local.conf`) vào `sites-available/` và tạo symlink sang `sites-enabled/`.
4. Vô hiệu hóa site mặc định của Nginx (`sites-enabled/default`).
5. Tạo các thư mục `/var/www/taskops-app` và `/var/www/taskops-status`, phân quyền cho user `www-data`.
6. Sao chép file build React (`app/static/*`) và giao diện trạng thái (`web/static/status/index.html`) vào thư mục tương ứng.
7. Đảm bảo tên miền `taskops.local` và `status.local` được ánh xạ về `127.0.0.1` trong `/etc/hosts`.
8. Kiểm tra cú pháp bằng `nginx -t` và `reload` dịch vụ Nginx.

---

## 4. Hướng dẫn kiểm thử & Xác thực (Verification)

### 4.1. Kiểm tra tính hợp lệ của chứng chỉ SSL
```bash
# Kiểm tra chứng chỉ server được ký đúng bởi CA
openssl verify -CAfile /etc/ssl/taskops/ca.crt /etc/ssl/taskops/taskops.crt

# Kiểm tra SAN (Subject Alternative Names) trong chứng chỉ
openssl x509 -in /etc/ssl/taskops/taskops.crt -noout -ext subjectAltName

# Kiểm tra quyền truy cập file khóa và chứng chỉ
ls -la /etc/ssl/taskops/
```

### 4.2. Kiểm tra HTTP 80 Redirect sang HTTPS 443 (Mã 301)
```bash
curl -I http://taskops.local
curl -I http://status.local
```
*Kết quả mong đợi:*
```http
HTTP/1.1 301 Moved Permanently
Server: nginx/...
Location: https://taskops.local/
```

### 4.3. Kiểm tra HTTPS & Giao thức bảo mật
```bash
# Truy cập taskops.local qua HTTPS với CA nội bộ
curl --cacert /etc/ssl/taskops/ca.crt -I https://taskops.local

# Truy cập status.local qua HTTPS
curl --cacert /etc/ssl/taskops/ca.crt https://status.local
```

### 4.4. Kiểm tra Reverse Proxy `/api/` tới NodeJS Backend
```bash
# Đảm bảo NodeJS app đang chạy tại 127.0.0.1:5000
curl --cacert /etc/ssl/taskops/ca.crt https://taskops.local/api/todos
```
*Kết quả:* Nginx nhận request HTTPS tại cổng 443, giải mã TLS, gắn các header `X-Forwarded-*` và chuyển tiếp đến backend NodeJS `127.0.0.1:5000/api/todos` rồi trả dữ liệu JSON về client.
