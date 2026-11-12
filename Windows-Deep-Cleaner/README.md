# Windows Deep Cleaner

Công cụ dọn dẹp Windows theo thiết kế trong `Windows-Deep-Cleaner-Solution.md`:
**quét và báo cáo trước, chỉ xóa khi người dùng xác nhận**, ưu tiên bảo toàn dữ liệu.

Yêu cầu: Windows 10/11, Windows PowerShell 5.1 (có sẵn). Không cần cài thêm gì.

## Cách dùng nhanh

Double-click `Windows-Deep-Cleaner.bat` (tự xin quyền Administrator), chọn:

| Phím | Chức năng |
|---|---|
| 1 | Quét + báo cáo HTML + menu dọn dẹp tương tác (khuyên dùng) |
| 2 | Chỉ quét, xuất báo cáo (Preview, không xóa gì) |
| 3 | Dọn Temp an toàn ngay (không hỏi, chỉ file tạm cũ hơn 7 ngày) |
| 4 | Áp dụng file CSV đã đánh dấu |
| 5 / 6 | Đăng ký / hủy lịch chạy tự động hằng tuần (chỉ dọn Temp) |

Hoặc chạy trực tiếp với tham số:

```bat
Windows-Deep-Cleaner.bat -PreviewOnly
Windows-Deep-Cleaner.bat -PreviewOnly -Drives D,E -Days 365
Windows-Deep-Cleaner.bat -AutoSafeClean
Windows-Deep-Cleaner.bat -ApplyReviewFile "reports\old-files_20261112_101500.csv"
Windows-Deep-Cleaner.bat -SkipApps -SkipBrowser
```

## Menu dọn dẹp (chế độ 1)

1. **Temp/WER** — `%TEMP%`, `C:\Windows\Temp`, Windows Error Reporting; chỉ file cũ hơn `tempFileDays`.
2. **DISM** — `/StartComponentCleanup`, **không** dùng `/ResetBase`.
3. **Recycle Bin** — xác nhận riêng, phải gõ `XOA`.
4. **Delivery Optimization** — chỉ qua cmdlet chính thức `Delete-DeliveryOptimizationCache`.
5. **Cache trình duyệt** — Chrome, Edge, Brave, Vivaldi, Opera, Firefox. Chỉ thư mục cache; không đụng password/cookie/session/history/profile. Trình duyệt đang chạy → yêu cầu đóng, nếu không thì bỏ qua (không tự tắt).
6. **File cũ theo nhóm** — chọn nhóm (bộ cài, media, tài liệu, temp rải rác), xem top 20 file lớn nhất, xử lý cả nhóm hoặc chỉ file > N MB. Mặc định **chuyển vào Recycle Bin**.
7. **Áp dụng CSV** — mở `reports\old-files_*.csv`, điền `YES` vào cột `Delete` cho từng file muốn xóa, lưu lại rồi chọn mục này.
8. **Gỡ ứng dụng** — chỉ ứng dụng không được bảo vệ; dùng trình gỡ chính thức (MSI `msiexec /x`, `UninstallString`, `Remove-AppxPackage`), xác nhận từng ứng dụng.

Kết thúc menu sẽ xuất báo cáo kết quả, phân biệt **dung lượng dự kiến** và **dung lượng thực tế đã giải phóng**.

## Cơ chế an toàn

- **Protected paths** (`config/exclusions.json`): Windows, Program Files, ProgramData, Desktop/Documents/Downloads/Pictures/Videos/Music, OneDrive, AppData... không bị quét hay xóa ở Storage Scanner.
- **Tên thư mục bảo vệ**: `.git`, `backup`, `docker`, `wsl`, `database`, `src`, `projects`, `VirtualBox VMs`...
- **Thư mục dự án**: thư mục chứa `.git`, `package.json`, `*.sln`, `pom.xml`, `go.mod`... bị bỏ qua toàn bộ.
- **Nhóm luôn được bảo vệ**: mã nguồn, database, backup/VM, file hệ thống, file không rõ loại.
- **Không đi theo symlink/junction** khi quét hoặc xóa; kiểm tra cả chuỗi thư mục cha trước khi xóa.
- **Xác minh lại trước khi xóa**: file phải còn nguyên kích thước và `LastWriteTime` như lúc quét.
- **Lỗi từng file không dừng tác vụ**; file khóa/không đủ quyền được ghi là `Skipped`.
- **Ứng dụng**: chỉ gắn nhãn `NeedsReview` khi có bằng chứng Prefetch (lần chạy cuối ≥ `appInactivityDays`). Không dùng ngày cài đặt hay Last Access để kết luận. Ứng dụng hệ thống, driver, runtime, security/VPN luôn được bảo vệ.

## Cấu hình — `config/settings.json`

| Khóa | Mặc định | Ý nghĩa |
|---|---|---|
| `oldFileDays` | 180 | Ngưỡng file cũ (theo `LastWriteTime`) |
| `tempFileDays` | 7 | Chỉ xóa file temp cũ hơn số ngày này |
| `minOldFileSizeMB` | 1 | Chỉ liệt kê file cũ ≥ N MB (vẫn được đếm trong thống kê) |
| `htmlMaxRows` | 500 | Số dòng tối đa trong bảng HTML (CSV luôn đầy đủ) |
| `appInactivityDays` | 180 | Ngưỡng Prefetch để gắn nhãn "Cần xem xét" |
| `additionalTempPaths` | `[]` | Thư mục temp bổ sung bạn chắc chắn là temp |
| `scheduledTask` | Chủ nhật 10:00 | Lịch chạy `-AutoSafeClean` |

Thêm thư mục cần bảo vệ vào `protectedPaths` trong `config/exclusions.json` (hỗ trợ `%BIEN_MOI_TRUONG%` và `*`).

## Kết quả đầu ra

- `reports/scan_report_*.html`, `reports/result_report_*.html` — báo cáo tổng hợp.
- `reports/old-files_*.csv`, `reports/applications_*.csv`, `reports/actions_*.csv`.
- `reports/history.json` — lịch sử 100 lần chạy gần nhất.
- `logs/cleanup_*.log` — log chi tiết mọi thao tác, lỗi, mục bị bỏ qua.

## Lưu ý

- File không thay đổi 180 ngày chỉ là file **cũ**, không phải bằng chứng là không cần.
- File xóa vĩnh viễn (Temp, cache, làm trống Recycle Bin) không thể khôi phục bằng công cụ này.
- Quét toàn bộ ổ đĩa lớn có thể mất vài phút đến vài chục phút.
