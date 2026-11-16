# TaskOps — Security Hardening

## G01 — UFW trên máy thực hành cá nhân

### Môi trường

- Ubuntu 22.04.5 LTS chạy trên VMware.
- Hostname: NhatNguyen-US.
- Thực hiện cấu hình qua console VMware.

### Chính sách tường lửa

- Chặn kết nối vào theo mặc định.
- Cho phép kết nối ra.
- Bật logging ở mức low.
- Cho phép các cổng TCP sau trên IPv4 và IPv6:

| Cổng | Mục đích |
|---|---|
| 22 | Quản trị từ xa bằng SSH |
| 80 | HTTP, phục vụ chuyển hướng sang HTTPS khi Nginx được cấu hình |
| 443 | Truy cập ứng dụng qua HTTPS khi Nginx được cấu hình |

Cho phép một cổng qua tường lửa không đồng nghĩa dịch vụ đã chạy
hoặc truy cập đầu-cuối đã được kiểm thử.

### Script cấu hình

Chạy từ thư mục gốc repository:

```bash
bash security/setup-ufw.sh --help
bash -n security/setup-ufw.sh
shellcheck security/setup-ufw.sh
sudo bash security/setup-ufw.sh
```

Script yêu cầu quyền quản trị, có xử lý lỗi và giữ nguyên các luật
UFW hiện có. Cần kiểm tra danh sách luật sau khi chạy để phát hiện
các luật mở thừa.

### Kiểm tra

```bash
sudo ufw status verbose
sudo ufw status numbered
```

Kết quả trên máy thực hành:
- UFW active.
- Default deny incoming, allow outgoing.
- Các luật cho phép vào gồm TCP 22, 80, 443 trên IPv4 và IPv6.

### File cấu hình và bằng chứng

| File trong repository | Nguồn / ý nghĩa |
|---|---|
| security/ufw/user.rules | Bản sao /etc/ufw/user.rules |
| security/ufw/user6.rules | Bản sao /etc/ufw/user6.rules |
| security/ufw/default-ufw | Bản sao /etc/default/ufw |
| security/ufw/ufw.conf | Bản sao /etc/ufw/ufw.conf |
| docs/evidence/G01/ | Kết quả kiểm tra và ảnh chụp phục vụ báo cáo |

Các bản sao phản ánh cấu hình máy thực hành tại thời điểm thu thập.

### Khi tích hợp lên VM nhóm

Bản hiện tại cho phép SSH từ mọi địa chỉ có thể kết nối tới máy.
Yêu cầu A03 của nhóm là giới hạn SSH qua Tailscale, nên cần điều chỉnh
luật SSH và kiểm thử trên mạng thực tế trước khi áp dụng lên VM nhóm.

VM2 chỉ mở các cổng cần cho vai trò sao lưu; không áp dụng mặc định
các luật mở cổng web của VM1.
