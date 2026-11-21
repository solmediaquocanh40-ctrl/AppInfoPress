# AppInfoPress 1.0.3

Mình là Quoc. Cái tweak này ra đời từ một thói quen bên Android mà mình rất nhớ khi dùng iPhone: ấn giữ icon của một app là hiện ngay mục **Thông tin ứng dụng** — bấm một cái là tới thẳng trang quản lý của app đó, xem dung lượng, xoá bộ nhớ đệm, đặt lại app. Bên iOS thì không có: mỗi lần muốn xoá cache hay xem app nào ngốn dung lượng là phải mở Cài đặt, vào Cài đặt chung, vào Dung lượng iPhone, chờ nó tải danh sách, rồi cuộn tìm đúng app. Mất cả phút cho một việc đáng ra chỉ cần hai chạm.

AppInfoPress gộp hai việc đó vào một tweak duy nhất: phần ngoài màn hình chính học theo Android, phần trong Cài đặt học theo tweak CacheClearer mà mình vẫn dùng — giờ gom lại một gói cho gọn, khỏi cài rời rạc.

## Nó làm được gì

**Ấn giữ icon ngoài màn hình chính**, menu hiện thêm tối đa 4 mục (bật/tắt từng mục trong Cài đặt của tweak):

- **Thông tin ứng dụng** — mở thẳng trang của app đó trong Cài đặt chung → Dung lượng iPhone: trang có Gỡ bỏ ứng dụng / Xoá ứng dụng và 2 nút Reset App / Clear App's Cache ở bên dưới — đúng kiểu trang App info của Android.
- **Dung lượng & bộ nhớ đệm** — cùng đích với mục Thông tin ứng dụng: vào thẳng trang của app đó trong Dung lượng iPhone.
- **Xoá bộ nhớ đệm** — xoá cache của app ngay tại màn hình chính, không cần rời đi đâu cả. Xoá xong báo luôn đã giải phóng được khoảng bao nhiêu MB. Chỉ xoá cache thôi: tài liệu, tài khoản đăng nhập giữ nguyên.
- **Đặt lại app** — đưa app về như mới cài: xoá sạch dữ liệu trong app (có hỏi xác nhận 2 lần, vì nút này xoá thật). App vẫn còn trên máy, chỉ dữ liệu là đi.

**Trong Cài đặt**, vào Cài đặt chung → Dung lượng iPhone → chọn một app, trang của app đó có thêm 2 nút **Reset App** và **Clear App's Cache** — đúng kiểu CacheClearer. Ai đang cài CacheClearer thì hoặc tắt phần này trong cài đặt của AppInfoPress, hoặc gỡ CacheClearer ra; để cả hai cùng chạy thì trang dung lượng sẽ hiện trùng hai cặp nút.

**Cài đặt của tweak** (Cài đặt → AppInfoPress): một công tắc tổng, bật/tắt riêng từng mục trong menu ấn giữ, bật/tắt 2 nút trong Cài đặt, và công tắc ghi log gỡ lỗi. Log nằm ở Documents/AppInfoPress.log — có gì lạ cứ gửi file đó cho người hỗ trợ là xem được chuyện gì đã xảy ra.

## Giới hạn mình nói thẳng

- Hai mục nhảy trang đều hướng vào trang của app trong Dung lượng iPhone; khâu tự nhảy vào đúng app phụ thuộc nội bộ của app Cài đặt — nếu có lúc nó chỉ dừng ở danh sách dung lượng thì chạm thêm một cái vào app là xong, không phải lỗi treo máy.
- Đặt lại app sẽ cố dừng app trước khi xoá dữ liệu; nếu app đang mở mà không dừng được, dữ liệu có thể bị app ghi lại một phần — tốt nhất đóng app trước khi đặt lại.
- Xoá bộ nhớ đệm chỉ dọn thư mục cache và tmp của app; vài app giấu cache ở chỗ khác (ví dụ dữ liệu web) thì con số giải phóng được sẽ ít hơn kỳ vọng.
- Tweak chạy trên máy jailbreak của mình: iPhone 12 Pro, iOS 16.3.1, Dopamine rootless. Máy khác, iOS khác chưa được kiểm chứng.

## Có gì mới ở 1.0.3

Đọc log máy thật của bản 1.0.2 thì thấy hai chuyện rõ ràng. Một: mỗi lần ấn giữ icon là Cài đặt mở nguội từ đầu, và nấc nhảy thứ hai của đường link (từ Cài đặt chung vào Dung lượng iPhone) bị rớt — Cài đặt cứ đứng ở các trang ngoài nên bên trong không có gì để chạy tiếp. Hai: ở các phiên cũ trong cùng file log, nút từng được gắn vào danh sách của trang chi tiết nhưng không hiện lên hình, vì kiểu ô của nút không khớp với kiểu ô nút bấm thật của trang. Bản này sửa cả hai:

- **Tự bấm dẫn đường:** bộ theo dõi trong Cài đặt giờ tự nhìn trang đang hiện: thấy mục **Cài đặt chung** thì bấm vào, thấy mục **Dung lượng iPhone** thì bấm tiếp, rồi mới chọn đúng app như trước. Không còn phụ thuộc vào nấc nhảy của đường link nữa — mở nguội hay mở nóng đều đi hết đường.
- **Nút dùng đúng kiểu ô của nút Gỡ bỏ / Xoá ứng dụng** (kiểu 13 theo log máy thật), và sau khi gắn nút, trang được nhờ nạp lại danh sách một lần để nút chắc chắn lên hình.

## Có gì mới ở 1.0.2

Bản 1.0.1 vẫn chưa hiện 2 nút và nhảy chưa tới nơi. Lần này mình đọc log thật trên máy (file log ghi lại toàn bộ hoạt động trong Cài đặt) và tìm được đúng nguyên nhân, sửa trúng từng điểm:

- Trang dung lượng của từng app do class `STStorageAppDetailController` dựng, và các mục trong đó **không có tên hiển thị** để mà nhận diện bằng chữ như bản cũ làm. Bản này nhận diện trang bằng chính tên class, đồng thời móc hook sớm hơn hẳn (quét liên tục ngay từ khi Cài đặt mở) để kịp trước khi trang được mở. Mã app cũng được đọc thẳng từ đối tượng dữ liệu của trang, kể cả quét các biến nội bộ của controller.
- Khâu tự nhảy: bản cũ vớ nhầm trang tổng quan của Dung lượng (trang đó không chứa app nào) và đọc danh sách lúc nó còn trống. Bản này nhắm đúng trang danh sách app `STStorageAppsController`, dò liên tục 0.15 giây một lần ngay khi trang hiện ra — dòng của app vừa xuất hiện là chạm vào liền, cảm giác như nhảy thẳng một mạch.
- Log được ghi gọn và rõ hơn: trang danh sách được in lại mỗi khi số mục thay đổi (thấy được lúc nó nạp đủ app), để nếu còn trục trặc thì nhìn một cái biết ngay kẹt ở đâu.

## Có gì mới ở 1.0.1

Bản 1.0.0 cài chạy được nhưng test máy thật lộ hai lỗi, bản này sửa cả hai:

- **2 nút Reset App / Clear App's Cache không hiện trên trang dung lượng.** Nguyên nhân: bản cũ nhận diện trang quá chặt (đòi có cả dòng dung lượng trong danh sách nút, mà trên iOS 16 dòng đó không nằm trong danh sách) và chỉ móc vào lớp cha của Cài đặt. Bản này nới điều kiện nhận diện và tự quét, móc thêm vào từng class của khu vực Dung lượng, kể cả các class nạp muộn.
- **Mục "Thông tin ứng dụng" nhảy sai chỗ.** Nay nó vào thẳng trang của app trong Dung lượng iPhone như mô tả ở trên. Khâu tự nhảy vào đúng app cũng được làm lại: thử lại nhiều lần trong lúc danh sách dung lượng đang nạp, thay vì thử đúng một lần rồi thôi.

## Build

Source Theos (gồm 3 phần: `sb` chích SpringBoard lo menu ấn giữ, `sett` chích Cài đặt lo 2 nút trang dung lượng, `prefs` là trang cài đặt của tweak). File workflow mẫu tên `build-appinfopress-1.0.3.yml` phải được đẩy vào `.github/workflows/build.yml` trên GitHub (GitHub không có sẵn), rồi **commit mới** — nút Re-run chỉ chạy lại workflow của commit cũ. Workflow chạy trên `macos-latest`, có cài `ldid`, xuất 3 bản rootful / rootless / roothide.

Gói: `com.anhdang.appinfopress` — made by Quoc.
