# Windows Deep Cleaner -- Solution Design

## 1. Mục tiêu

Xây dựng bộ công cụ dọn dẹp Windows định kỳ, có khả năng quét tất cả ổ
đĩa cố định (C:, D:, E:...), giải phóng dung lượng và phát hiện file/ứng
dụng có khả năng không còn cần thiết.

Ưu tiên cao nhất là **bảo toàn dữ liệu**. Công cụ không được tự ý xóa dữ
liệu cá nhân hoặc gỡ ứng dụng chỉ dựa trên việc chúng không được sử dụng
trong thời gian dài.

## 2. Nguyên tắc thiết kế

1.  **Preview before cleanup:** mặc định quét và lập báo cáo trước;
    không xóa ngay.
2.  **Explicit approval:** các thao tác ảnh hưởng đến dữ liệu người dùng
    phải được xác nhận rõ ràng.
3.  **Conservative by default:** nếu không chắc một file có an toàn để
    xóa hay không, giữ nguyên.
4.  **Protected locations:** không tự động xóa dữ liệu trong Documents,
    Desktop, Downloads, Pictures, Videos, thư mục dự án, mã nguồn, cơ sở
    dữ liệu và thư mục backup.
5.  **Audit log:** ghi lại thao tác, kết quả, lỗi và các mục bị bỏ qua.
6.  **No destructive system tuning:** không xóa Restore Point, không xóa
    driver, không dùng DISM `/ResetBase`, không chỉnh Registry tùy tiện.
7.  **No false inactivity claims:** không coi ngày cài đặt hoặc Last
    Access là bằng chứng chắc chắn rằng ứng dụng/file không còn được
    dùng.

## 3. Kiến trúc tổng thể

``` text
Windows Deep Cleaner
│
├── Launcher (BAT)
│   ├── Kiểm tra quyền Administrator
│   └── Khởi chạy PowerShell
│
├── Safety Controller
│   ├── Protected paths / exclusions
│   ├── Quy tắc phân loại
│   ├── Preview và xác nhận
│   └── Kiểm soát thao tác xóa
│
├── System Cleaner
│   ├── User Temp
│   ├── Windows Temp
│   ├── Cache hệ thống được hỗ trợ
│   └── DISM Component Store Cleanup
│
├── Storage Scanner
│   ├── Quét tất cả fixed drives
│   ├── Tìm file không sửa đổi trong 180 ngày
│   ├── Phân loại theo loại và vị trí
│   └── Thống kê dung lượng
│
├── Application Manager
│   ├── Liệt kê ứng dụng Win32/MSI
│   ├── Liệt kê ứng dụng Microsoft Store
│   ├── Thu thập publisher, version, size khi có
│   └── Đề xuất ứng dụng cần người dùng xem xét
│
├── Browser Cache Cleaner (tùy chọn)
│   └── Chỉ dọn cache được chọn; không xóa profile/cookie/password
│
└── Reporting
    ├── HTML report
    ├── CSV export
    ├── JSON configuration/history
    └── Cleanup log
```

## 4. Module 1 -- System Cleaner

### Phạm vi

-   Thư mục `%TEMP%` của người dùng hiện tại.
-   `C:\Windows\Temp`.
-   Các thư mục Temp tiêu chuẩn được xác định rõ trên những ổ đĩa khác
    (nếu có).
-   Windows component store thông qua DISM
    `/Online /Cleanup-Image /StartComponentCleanup`.
-   Một số cache Windows có API/công cụ dọn chính thức và có thể kiểm
    soát.

### Quy tắc

-   Chỉ xóa file tạm đủ điều kiện, ví dụ cũ hơn 7 ngày.
-   Bỏ qua file đang được tiến trình sử dụng, file bị khóa hoặc không đủ
    quyền.
-   Không xóa thủ công `SoftwareDistribution`, `WinSxS`, thư mục driver
    store hoặc các thư mục hệ thống không có quy trình hỗ trợ.
-   Không sử dụng `/ResetBase`, để tránh làm mất khả năng gỡ một số bản
    cập nhật Windows.
-   Cache Delivery Optimization và Recycle Bin phải có bước xác nhận
    riêng.

## 5. Module 2 -- Storage Scanner: file cũ hơn 180 ngày

### Cách xác định

-   Dùng `LastWriteTime` (thời gian chỉnh sửa gần nhất) làm tiêu chí
    chính.
-   Mốc mặc định: 180 ngày.
-   Không dùng `LastAccessTime` làm tiêu chí chính vì Windows có thể
    không cập nhật thời gian truy cập chính xác hoặc tính năng này có
    thể bị tắt.
-   File có metadata không đọc được, đường dẫn không rõ hoặc quyền truy
    cập hạn chế phải được đánh dấu `Unknown/Skipped`.

### Phân loại và chính sách

  -----------------------------------------------------------------------
  Nhóm                    Ví dụ                   Chính sách mặc định
  ----------------------- ----------------------- -----------------------
  File tạm                Temp, cache được nhận   Có thể tự dọn theo quy
                          diện                    tắc an toàn

  File cài đặt/tải về     ISO, EXE, MSI, ZIP, RAR Liệt kê để người dùng
                                                  duyệt

  Ảnh/video/audio         JPG, PNG, MP4, MOV, MP3 Không tự xóa

  Tài liệu                PDF, DOCX, XLSX, PPTX   Không tự xóa

  Dự án/mã nguồn          Git repo, source code,  Bảo vệ
                          project                 

  Cơ sở dữ liệu           DB, dump, SQLite,       Bảo vệ
                          MongoDB backup          

  Backup/restore          Backup, archive,        Bảo vệ
                          snapshot                

  File hệ thống           Windows, Program Files, Không quét xóa tự động
                          ProgramData             

  Không rõ loại           File không phân loại    Giữ nguyên
                          được                    
  -----------------------------------------------------------------------

### Exclusion bắt buộc

-   `C:\Windows`
-   `C:\Program Files`
-   `C:\Program Files (x86)`
-   `C:\ProgramData` (trừ cache cụ thể có quy trình hỗ trợ)
-   `System Volume Information`
-   `$Recycle.Bin` (xử lý bằng bước riêng)
-   Thư mục người dùng: Desktop, Documents, Downloads, Pictures, Videos,
    Music
-   Thư mục dự án, repository, workspace, VM, Docker volume, database và
    backup
-   Các thư mục được người dùng thêm vào danh sách bảo vệ

### Hành vi

1.  Quét và phân loại.
2.  Tạo báo cáo gồm đường dẫn, dung lượng, loại file, Last Modified và
    lý do được đưa vào danh sách.
3.  Không xóa file cá nhân trong chế độ tự động.
4.  Người dùng có thể chọn từng mục hoặc nhóm mục để xử lý.
5.  Trước khi xóa, hiển thị tổng dung lượng và số lượng mục được chọn.

**Lưu ý:** file không thay đổi trong 180 ngày chỉ là file cũ, không phải
bằng chứng file không còn cần thiết.

## 6. Module 3 -- Application Manager

### Nguồn dữ liệu

-   Danh sách ứng dụng Win32/MSI từ các nguồn đăng ký cài đặt Windows
    phù hợp.
-   Microsoft Store/AppX packages.
-   Thu thập tên, publisher, version, install date và estimated size khi
    hệ thống cung cấp.

Không được giả định mọi ứng dụng đều cung cấp đầy đủ ngày sử dụng cuối
cùng hoặc dung lượng chính xác.

### Đánh giá ứng dụng ít sử dụng

Một ứng dụng chỉ nên được gắn nhãn **"Cần xem xét"** khi có bằng chứng
phù hợp. Có thể sử dụng dữ liệu đáng tin cậy nếu hệ thống hoặc ứng dụng
cung cấp, chẳng hạn lịch sử sử dụng được quản lý rõ ràng.

Không dùng riêng các yếu tố sau để kết luận ứng dụng không dùng 6 tháng:

-   Ngày cài đặt.
-   Ngày cập nhật.
-   Last Access của file EXE.
-   Việc không tìm thấy log chạy ứng dụng.

### Nhóm ứng dụng

  Nhóm                           Chính sách
  ------------------------------ ---------------------------------
  Ứng dụng người dùng            Có thể đề xuất gỡ sau khi duyệt
  Ứng dụng hệ thống              Không tự gỡ
  Driver và phần mềm phần cứng   Bảo vệ
  Runtime/framework              Bảo vệ mặc định
  Security/antivirus/VPN         Bảo vệ mặc định
  Ứng dụng không rõ publisher    Cần kiểm tra thủ công

### Quy trình gỡ cài đặt

-   Hiển thị tên, publisher, version, dung lượng ước tính và phương thức
    uninstall.
-   Ưu tiên trình gỡ cài đặt chính thức của ứng dụng.
-   Không tự chạy lệnh uninstall không rõ nguồn gốc.
-   Không xóa thư mục ứng dụng thủ công để thay thế quy trình uninstall.
-   Yêu cầu xác nhận riêng trước mỗi lần gỡ hoặc trước một nhóm ứng dụng
    đã được người dùng chọn.
-   Ghi log kết quả và lỗi.

## 7. Module 4 -- Browser Cache Cleaner (tùy chọn)

-   Hỗ trợ trình duyệt phổ biến nếu xác định được cache path và quy
    trình an toàn.
-   Chỉ dọn cache được người dùng chọn.
-   Không xóa password, cookie, session, bookmarks, history hoặc browser
    profile.
-   Đóng trình duyệt trước khi dọn; nếu còn tiến trình sử dụng file thì
    bỏ qua.
-   Không xóa toàn bộ thư mục profile.

## 8. Module 5 -- Safety & Recovery

### Trước khi dọn

-   Kiểm tra quyền Administrator khi cần.
-   Xác định fixed drives và trạng thái ổ đĩa.
-   Kiểm tra đường dẫn đích nằm trong phạm vi cho phép.
-   Kiểm tra symbolic link/junction để tránh đi xuyên sang vùng dữ liệu
    ngoài ý muốn.
-   Hiển thị Preview trước khi thực thi.
-   Tạo log và lưu cấu hình trước thao tác.

### Trong khi dọn

-   Xử lý từng mục độc lập; lỗi một file không làm dừng toàn bộ tác vụ.
-   Bỏ qua file đang khóa, quyền truy cập bị từ chối hoặc metadata bất
    thường.
-   Không dùng wildcard xóa diện rộng ở thư mục không được xác minh.
-   Không theo symbolic link/reparse point khi quét hoặc xóa nếu chưa có
    xử lý an toàn.

### Sau khi dọn

-   Ghi số file đã xóa, số file bỏ qua, số lỗi và dung lượng ước tính
    giải phóng.
-   Ghi lại thời gian, ổ đĩa, module và thao tác.
-   Xuất báo cáo HTML/CSV.
-   Không tuyên bố có thể khôi phục file đã xóa vĩnh viễn. Recycle Bin
    và thao tác xóa trực tiếp có mức độ khôi phục khác nhau.

## 9. Workflow hoạt động

``` mermaid
flowchart TD
    A["Khởi chạy BAT"] --> B["Kiểm tra quyền và môi trường"]
    B --> C["Phát hiện fixed drives"]
    C --> D["Quét hệ thống, file và ứng dụng"]
    D --> E["Áp dụng exclusions và phân loại"]
    E --> F["Tạo Preview / Báo cáo"]
    F --> G{"Người dùng duyệt?"}
    G -->|Không| H["Kết thúc, không xóa"]
    G -->|Có| I["Xác nhận từng nhóm thao tác"]
    I --> J["Thực hiện cleanup"]
    J --> K["Ghi log và thống kê"]
    K --> L["Xuất báo cáo kết quả"]
```

## 10. Giao diện báo cáo đề xuất

Ví dụ minh họa, không phải số liệu thực tế:

  Chỉ số                               Kết quả
  ---------------------------------- ---------
  Dung lượng có thể dọn                12.5 GB
  File cũ hơn 180 ngày cần xem xét       1,248
  Ứng dụng cần xem xét                       8
  Ổ đĩa đã quét                              4

Các nhóm trạng thái:

-   **Có thể dọn:** cache/temp đã được xác định và đáp ứng quy tắc an
    toàn.
-   **Chờ duyệt:** file cá nhân cũ, bộ cài, ứng dụng đề xuất gỡ.
-   **Được bảo vệ:** dữ liệu cá nhân, source code, backup, database,
    driver và file hệ thống.
-   **Bị bỏ qua:** file đang sử dụng, không đủ quyền hoặc không xác định
    được an toàn.

## 11. Công nghệ và cấu trúc dự án

### Công nghệ

-   BAT: launcher, kiểm tra quyền Administrator và gọi PowerShell.
-   PowerShell: quét file, phân loại, truy vấn ứng dụng, cleanup và
    logging.
-   JSON: cấu hình, danh sách bảo vệ, lịch sử.
-   CSV: xuất danh sách file/ứng dụng để duyệt.
-   HTML: báo cáo tổng hợp dễ đọc.

### Cấu trúc thư mục đề xuất

``` text
Windows-Deep-Cleaner/
├── Windows-Deep-Cleaner.bat
├── src/
│   ├── Main.ps1
│   ├── SafetyController.ps1
│   ├── SystemCleaner.ps1
│   ├── StorageScanner.ps1
│   ├── ApplicationManager.ps1
│   ├── BrowserCleaner.ps1
│   └── Reporter.ps1
├── config/
│   ├── settings.json
│   └── exclusions.json
├── reports/
├── logs/
└── README.md
```

## 12. Lộ trình triển khai

### Phase 1 -- Safe System Cleanup

-   BAT launcher và quyền Administrator.
-   Dọn Temp an toàn.
-   DISM Component Store Cleanup không dùng ResetBase.
-   Log thao tác.
-   Xác nhận Recycle Bin và Delivery Optimization riêng.

### Phase 2 -- Storage Scanner

-   Quét tất cả fixed drives.
-   Phân loại file cũ hơn 180 ngày.
-   Exclusions và protected paths.
-   Xuất CSV/HTML Preview.
-   Chưa tự xóa file cá nhân.

### Phase 3 -- Application Manager

-   Liệt kê Win32/MSI và Store apps.
-   Phân loại ứng dụng hệ thống, driver, runtime và ứng dụng người dùng.
-   Đề xuất ứng dụng cần xem xét khi có dữ liệu sử dụng đáng tin cậy.
-   Gỡ cài đặt có xác nhận.

### Phase 4 -- Browser Cleaner & Reporting

-   Dọn cache trình duyệt có lựa chọn.
-   Báo cáo tổng hợp theo ổ đĩa/module.
-   Lịch sử các lần chạy.
-   Kiểm thử lỗi và tình huống file đang được sử dụng.

## 13. Tiêu chí nghiệm thu

-   Không xóa dữ liệu cá nhân khi chưa có xác nhận rõ ràng.
-   Không tự gỡ ứng dụng.
-   Không xóa nhầm source code, database, backup, driver hoặc file hệ
    thống.
-   Quét được các fixed drives có thể truy cập.
-   Có Preview trước khi thực thi.
-   Có log cho cả thành công, lỗi và mục bị bỏ qua.
-   Không dừng toàn bộ tiến trình chỉ vì một file bị khóa.
-   Báo cáo phân biệt dung lượng dự kiến và dung lượng thực tế giải
    phóng.
-   Có thể chạy lại an toàn mà không gây lỗi do dữ liệu đã được dọn ở
    lần trước.

## 14. Quyết định thiết kế cuối cùng

**Đề xuất:** giữ BAT làm launcher, chuyển toàn bộ logic chính sang
PowerShell theo module. Mặc định chạy ở chế độ Preview; chỉ tự động dọn
những cache/temp đã được xác định an toàn. File cá nhân cũ hơn 180 ngày
và ứng dụng nghi không sử dụng 6 tháng chỉ được đưa vào danh sách đề
xuất để người dùng duyệt.

Đây là hướng triển khai phù hợp nhất nếu ưu tiên hàng đầu là giải phóng
dung lượng nhưng vẫn bảo vệ dữ liệu và tính ổn định của Windows.
