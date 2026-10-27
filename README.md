# WinSlim

Công cụ tối ưu Windows 10/11 dạng menu, lấy cảm hứng từ `christitus.com/win` nhưng tập trung vào **máy yếu, RAM thấp, SSD nhỏ**.

Mục tiêu không phải "thần dược": WinSlim giảm app rác, dịch vụ nền, telemetry, hiệu ứng hình ảnh và vài tác vụ định kỳ; đồng thời giải phóng dung lượng. Mọi thay đổi registry/service/task đều được ghi lại để có thể hoàn tác.

> **Cảnh báo:** đây là script chỉnh sửa hệ thống, không có chữ ký số. Hãy đọc code, tạo System Restore point và dùng `-DryRun` trước nếu bạn chưa chắc. Tự chịu rủi ro khi chạy.
>
> Không dùng cho máy do công ty/quản trị viên quản lý (domain-joined/Intune), vì việc tắt telemetry service có thể vi phạm chính sách. Nên chạy bằng đúng tài khoản của bạn và bấm UAC (đừng đăng nhập tài khoản admin khác), để phần Revert khôi phục đúng HKCU.

---

## Chạy nhanh

1. Mở thư mục `WinSlim`.
2. Nhấp đôi **`Run WinSlim.cmd`**, hoặc mở PowerShell tại thư mục này:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1
```

3. Bấm **Yes** ở hộp UAC (tool cần quyền Admin để sửa registry/service).
4. Chọn **`3` – BALANCED** nếu bạn muốn cấu hình an toàn, phù hợp đa số máy yếu.
5. Máy rất yếu (2–4 GB RAM): nhấp đôi **`WinSlim Ultra.cmd`** và chọn `1` để chạy preset Ultra.

Chạy thử không ghi bất cứ thứ gì:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Preset Balanced -DryRun -NoElevate
```

Xem báo cáo máy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Report -NoElevate
```

---

## Các preset

| Preset | Nội dung | Phù hợp |
|---|---|---|
| **Safe** | Riêng tư/telemetry: tắt quảng cáo, gợi ý, web search, activity history; tắt DiagTrack và task telemetry | Ai chỉ muốn bớt theo dõi/quảng cáo |
| **Balanced** | Safe + gỡ app rác có chọn lọc + tắt background app/Game DVR + giảm hiệu ứng + power plan hiệu năng (giữ Ultimate/High nếu đang bật) + tweak multimedia | Đa số máy yếu (khuyến nghị) |
| **Aggressive** | Balanced + tắt hibernation/Fast Startup + tắt SysMain nếu là SSD + dọn temp | Máy SSD, ít dung lượng, chấp nhận đánh đổi |
| **Ultra** | Aggressive + tắt animation/thumbnail, tắt Xbox/Insider/Geolocation, gộp svchost, tắt auto-start OneDrive/Teams/Edge, tắt Search nếu RAM ≤ 4 GB, gỡ thêm app nặng | Máy rất yếu: 2–4 GB RAM, CPU đời cũ |

Menu **Custom** cho phép chạy từng phần riêng. Menu **Advanced** chứa các mục đánh đổi rõ ràng hơn: tắt Windows Search, tắt Xbox services, gỡ OneDrive, tắt tăng tốc chuột.

---

## Ultra cho máy 2–4 GB RAM

Mở **`WinSlim Ultra.cmd`** để có menu riêng, hoặc chạy trực tiếp:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Preset Ultra
```

Ultra làm thêm so với Aggressive:

- **Giao diện:** tắt animation, transparency, bóng đổ, thumbnail (folder chỉ hiện icon), kéo cửa sổ không hiện nội dung, bỏ delay menu/startup.
- **RAM:** gộp svchost trên máy ≤ 6.5 GB, tắt Xbox/Insider/Geolocation, tắt Windows Search nếu RAM ≤ 4 GB.
- **Auto-start:** tắt entry OneDrive, Teams, Cortana, Skype, Edge auto-launch (không gỡ app, dữ liệu vẫn còn).
- **Edge:** tắt background mode + startup boost, bật sleeping tabs sau 5 phút.
- **Debloat thêm:** Widgets, Mail & Calendar, Phone Link, Dev Home, Power Automate, new Outlook, Movies & TV, Copilot.
- **Ổ đĩa:** tắt hibernation/Fast Startup; tắt SysMain và prefetch **chỉ trên SSD**. Trên HDD vẫn giữ SysMain để máy đỡ khựng.
- **Khác:** tắt thêm vài task bảo trì/telemetry, giảm ưu tiên tải peer-to-peer của Delivery Optimization.

Ultra **không** tắt Defender, Firewall, Windows Update, không xoá pagefile/prefetch, không tắt Print Spooler (để “Microsoft Print to PDF” vẫn dùng được).

> **Đánh đổi:** Start menu search kém đi trên máy ≤ 4 GB; folder không còn ảnh thumbnail; app đã gỡ phải cài lại từ Store; một số app cần Xbox/Insider/Geolocation sẽ không chạy. Chỉ dùng Ultra khi bạn chấp nhận những đánh đổi này. Máy ≥ 8 GB nên dùng Balanced.

---

## WinSlim thay đổi gì?

- **Privacy/telemetry:** Advertising ID, activity feed, tailored experiences, gợi ý app, widget, Copilot/Recall (khi được hỗ trợ), web search trong Start, task telemetry.
- **Debloat:** gỡ app Store rác/ít dùng cho user hiện tại và gói provisioned (Candy Crush, TikTok, Facebook, News, Weather, Cortana, Clipchamp, v.v.). Không đụng Store, Terminal, Photos, Calculator, Paint, Notepad, Camera, Security.
- **Services/tasks:** DiagTrack, dmwappushservice, MapsBroker, RetailDemo, WMPNetworkSvc, RemoteRegistry, Fax; một số task CEIP/WER/WinSAT.
- **Hiệu năng/UI:** giảm animation/transparency, tắt Game DVR, chặn background app, menu mở nhanh hơn.
- **Ultra:** tắt thumbnail/animation mạnh hơn, gộp svchost, tắt thêm Xbox/Insider/Geolocation, tắt auto-start OneDrive/Teams/Edge, tắt Search trên máy ≤ 4 GB, gỡ thêm app nặng.
- **Power:** giữ High/Ultimate Performance (hoặc plan custom) nếu đang bật; nếu đang ở Balanced/Power saver thì chuyển sang High performance. Đặt CPU minimum 5% để máy không nóng/ồn cả ngày.
- **Network/multimedia:** giảm network throttling, ưu tiên multimedia/game, flush DNS.
- **Cleanup:** temp của user/Windows, cache Delivery Optimization, Recycle Bin (tuỳ chọn), DISM component cleanup (tuỳ chọn).

### WinSlim **không** làm

- Không tắt Windows Defender, Firewall hay Windows Update.
- Không xoá pagefile, prefetch, System Restore.
- Không "tăng RAM ảo", không dùng RAM cleaner, không chỉnh registry ngẫu nhiên.
- Không phải mọi máy sẽ nhanh hơn rõ rệt. Với máy HDD, nâng cấp lên SSD hiệu quả hơn toàn bộ script này.

---

## Hoàn tác

1. Chọn **`R`** trong menu chính.
2. Chọn bản backup gần nhất (ví dụ `[1] 20261027-203700`).
3. WinSlim khôi phục giá trị registry, trạng thái service, task và power plan đã lưu.

Lưu ý:

- **App đã gỡ không được tự cài lại.** Mở Microsoft Store để cài lại, hoặc dùng System Restore.
- **Auto-start đã tắt được khôi phục** cùng registry/service/task (Ultra lưu từng entry trước khi xoá).
- Cleanup temp/Recycle Bin và gỡ OneDrive là hành động không thể hoàn tác bằng Revert.
- Bản backup chỉ chứa thay đổi do WinSlim tạo. Nếu bạn tự sửa registry sau đó, Revert có thể ghi đè giá trị mới đó.
- Trong menu Revert có mục **`S`** để mở System Restore của Windows.

Thư mục backup: `C:\ProgramData\WinSlim\Backups`  
Log: `%LOCALAPPDATA%\WinSlim\Logs`

---

## Tham số dòng lệnh

```text
-Preset Menu|Safe|Balanced|Aggressive|Ultra   Chọn preset (mặc định Menu)
-Yes                                    Không hỏi xác nhận (dùng cẩn thận)
-DryRun                                 Chỉ mô phỏng, không ghi thay đổi
-NoRestorePoint                         Không tạo System Restore point
-NoElevate                              Không tự xin quyền Admin (chế độ chỉ đọc)
-Report                                 In báo cáo hệ thống rồi thoát
```

Ví dụ chạy Balanced không hỏi:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Preset Balanced -Yes
```

Chạy Aggressive trên máy SSD:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Preset Aggressive -Yes
```

Chạy Ultra trên máy 2–4 GB RAM:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Preset Ultra -Yes
```

Xem trước Ultra mà không ghi gì:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSlim.ps1 -Preset Ultra -DryRun -NoElevate
```

---

## Đánh đổi cần biết

- **Background apps:** thông báo từ app Store (WhatsApp, Phone Link, v.v.) có thể không nổi khi app đóng.
- **Debloat:** app bị gỡ có thể cần thiết cho workflow của bạn; xem danh sách trước khi xác nhận.
- **Windows Search:** nếu tắt ở menu Advanced, Start/File Explorer tìm file chậm hoặc kém chính xác hơn.
- **SysMain:** chỉ nên tắt trên SSD. HDD vẫn cần Superfetch. Ultra tự giữ SysMain trên HDD.
- **Windows Search (Ultra):** trên máy ≤ 4 GB, Ultra tắt WSearch để tiết kiệm RAM. Start menu vẫn mở được nhưng tìm file/app kém chính xác và chậm hơn.
- **svchost (Ultra):** gộp service host giúp tiết kiệm RAM nhưng giảm cô lập giữa các service. Revert khôi phục giá trị cũ.
- **Auto-start (Ultra):** OneDrive/Teams/Edge không tự chạy khi đăng nhập; app và dữ liệu vẫn còn, mở thủ công vẫn được.
- **Xbox/Insider/Geolocation (Ultra):** game Store/Game Pass, Windows Insider và tính năng vị trí có thể không hoạt động cho đến khi bật lại.
- **Thumbnail (Ultra):** folder chỉ hiện icon, không hiện ảnh xem trước; đổi lại Explorer nhẹ hơn trên HDD/CPU yếu.
- **Hibernation off:** mất Fast Startup và tính năng ngủ đông; đổi lại giải phóng vài GB.
- **Power plan:** High/Ultimate Performance làm pin laptop tụt nhanh hơn; CPU min 5% giúp giảm nhiệt nhưng không loại bỏ hoàn toàn.
- **Visual effects:** một số thay đổi cần đăng xuất/khởi động lại mới thấy.
- **OneDrive:** gỡ app không xoá file trong thư mục OneDrive; dữ liệu cloud vẫn còn trên tài khoản Microsoft.

---

## Tải về / GitHub

Repo: **https://github.com/gbetokuon-stack/WinSlim**

```powershell
git clone https://github.com/gbetokuon-stack/WinSlim.git
cd WinSlim
.\Run WinSlim.cmd
```

Hoặc tải nhanh chỉ script chính (không có `WinSlim Ultra.cmd`):

```powershell
irm https://raw.githubusercontent.com/gbetokuon-stack/WinSlim/main/WinSlim.ps1 -OutFile "$env:TEMP\WinSlim.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\WinSlim.ps1"
```

WinSlim cần chạy từ file (để tự nâng quyền), nên đừng dùng `irm ... | iex`. Script không tự tải thêm gì từ Internet.

---

## Mẹo thực tế cho máy yếu

1. **Nâng cấp SSD** nếu còn HDD – hiệu quả lớn nhất.
2. **16 GB RAM** nếu máy chỉ có 8 GB và hay mở trình duyệt/IDE.
3. Giảm startup app trong **Task Manager → Startup apps**.
4. Dùng **Balanced** trước; chỉ dùng **Aggressive/Ultra/Advanced** khi hiểu đánh đổi.
5. Kiểm tra nhiệt độ, vệ sinh quạt, cập nhật driver chipset/GPU.
6. Đừng cài nhiều "RAM cleaner"/"game booster" – chúng thường làm hại hơn lợi.
