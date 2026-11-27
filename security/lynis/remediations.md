# G03 — Auditd và đánh giá Lynis

## Môi trường và kết quả

- Máy thực hành cá nhân: Ubuntu 22.04.5 LTS trên VMware.
- Hostname: NhatNguyen-US.
- Ngày đánh giá: 16/11/2026.
- Phiên bản Lynis trước và sau: 3.0.7.
- Hardening index: từ 60 lên 63.

Điểm Lynis là chỉ số tham khảo, không chứng minh hệ thống đã an toàn
toàn diện. Kết quả này áp dụng cho máy thực hành, chưa phải VM nhóm.

## Các biện pháp khắc phục

| Mã kiểm tra | Phát hiện ban đầu | Biện pháp | Kết quả đánh giá lại |
|---|---|---|---|
| FIRE-4512 | Chưa có luật tường lửa hoạt động | Bật UFW, mặc định chặn vào, cho phép TCP 22/80/443 | Không còn cảnh báo FIRE-4512 |
| ACCT-9630 | Auditd chạy với bộ luật trống | Thêm luật theo dõi đọc, ghi và thay đổi thuộc tính của /etc/passwd và /etc/shadow | Không còn đề xuất ACCT-9630 |
| SSH-7408 | MaxAuthTries và LogLevel chưa theo đề xuất | Đặt MaxAuthTries 3 và LogLevel VERBOSE | Hai đề xuất tương ứng không còn; các đề xuất SSH khác vẫn tồn tại |

SSH còn được cấu hình cấm root, tắt xác thực bằng mật khẩu,
yêu cầu khóa công khai và giới hạn AllowUsers ở phần G02.

## Cấu hình và kiểm thử Auditd

File nguồn: security/auditd/50-taskops-identity.rules

File cài đặt: /etc/audit/rules.d/50-taskops-identity.rules

Hai luật dùng nhãn taskops_identity, giám sát quyền rwa:
- r: đọc.
- w: ghi.
- a: thay đổi thuộc tính.

Đã nạp luật bằng sudo augenrules --load và kiểm tra bằng
sudo auditctl -l.

Kiểm thử bằng cat /etc/passwd > /dev/null:
- Sự kiện 799 ghi nhận /usr/bin/cat mở /etc/passwd để đọc.
- success=yes, auid=nguyennhat, key=taskops_identity.
- Sự kiện 804 ghi nhận sudo truy cập /etc/shadow.
- Không đưa nội dung /etc/shadow vào bằng chứng.

Sau reboot, auditd vẫn active và cả hai luật vẫn được nạp.

## Bằng chứng

- security/lynis/before/: log và báo cáo baseline, 60 điểm.
- security/lynis/after/: log và báo cáo sau gia cố, 63 điểm.
- docs/evidence/G03/: luật đang hoạt động, sự kiện truy cập
  và kết quả kiểm tra sau reboot.
- docs/evidence/G01/: trạng thái UFW.
- docs/evidence/G02/: kiểm thử SSH và Fail2ban.

## Hạn chế còn tồn tại

- PKGS-7392: lần quét sau gia cố ghi nhận 417 bản cập nhật bảo mật
  đang chờ theo apt-check. Chưa thực hiện đợt cập nhật này.
  Đây không phải số lỗ hổng đã được xác minh riêng biệt.
- SSH-7408 còn các đề xuất khác chưa áp dụng. Giữ cổng 22 phù hợp
  với cấu hình hiện tại; tài khoản được giới hạn bằng AllowUsers.
- Khi triển khai VM nhóm, cần điều chỉnh danh sách tài khoản SSH
  và giới hạn truy cập SSH qua Tailscale theo A03.
- Báo cáo sau gia cố được tạo trước lần reboot kiểm tra Auditd;
  bằng chứng sau reboot được lưu riêng.

## Công việc tiếp theo

Lập đợt bảo trì cập nhật các gói bảo mật, kiểm thử lại dịch vụ,
chạy lại Lynis và lưu kết quả thành một lần đánh giá mới.
