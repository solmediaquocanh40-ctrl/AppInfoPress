#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const AIPPrefsDomain;               // com.anhdang.appinfopress
extern NSString * const AIPPrefsChangedNotification;  // com.anhdang.appinfopress/prefsChanged

// Ghi log vào /var/mobile/Documents/AppInfoPress.log (cả SpringBoard lẫn Cài đặt đều ghi chung).
void AIPLog(NSString *format, ...);

// Đọc prefs của tweak (CFPreferences, đọc được từ mọi tiến trình).
NSDictionary *AIPLoadPrefs(void);
BOOL AIPPrefEnabled(NSDictionary *prefs, NSString *key, BOOL fallback);

// Ghi 1 khoá prefs (dùng để SpringBoard nhắn "mở trang dung lượng của app X" cho phía Cài đặt).
void AIPSetPrefValue(NSString *key, id _Nullable value);

// Thư mục dữ liệu (container) của app theo bundle id — qua LSApplicationWorkspace,
// dự phòng quét metadata trong /var/mobile/Containers/Data/Application.
NSURL * _Nullable AIPDataContainerURLForBundleID(NSString *bundleID);
NSString *AIPAppNameForBundleID(NSString *bundleID, NSString *fallback);

unsigned long long AIPSizeOfDirectory(NSString *path);
// Xoá toàn bộ nội dung bên trong 1 thư mục (giữ lại thư mục), trả số byte giải phóng.
unsigned long long AIPClearContentsOfDirectory(NSString *path);
// Xoá bộ nhớ đệm của app: nội dung Library/Caches + tmp. Trả -1 nếu không thấy container.
long long AIPClearCacheForBundleID(NSString *bundleID);
// Đặt lại app: xoá nội dung Documents + Library + tmp. Trả -1 nếu không thấy container.
long long AIPResetDataForBundleID(NSString *bundleID);

NSString *AIPByteString(unsigned long long bytes);

NS_ASSUME_NONNULL_END
