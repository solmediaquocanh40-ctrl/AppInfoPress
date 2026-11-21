// AppInfoPress (phần Cài đặt) — com.anhdang.appinfopress
// Hai việc:
//  1) Gắn 2 nút "Reset App" / "Clear App's Cache" vào cuối trang dung lượng
//     của từng app (Cài đặt chung -> Dung lượng iPhone -> chọn app), giống
//     CacheClearer. Trang đó do class STStorageAppDetailController dựng
//     (bằng chứng: log máy thật iOS 16.3.1) — nhận diện bằng TÊN CLASS,
//     vì các mục trong trang này có tên hiển thị rỗng.
//  2) Khi phía SpringBoard nhờ (ghi mã app vào prefs), tự nhảy vào đúng app
//     trong trang danh sách STStorageAppsController: dò liên tục 0.15s/lần
//     ngay khi trang hiện ra, dòng của app vừa có mặt là chạm vào liền.
// Mọi truy cập class hệ thống đều dò bằng respondsToSelector/objc_msgSend,
// không có thì bỏ qua êm, không văng Cài đặt.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "AIPShared.h"

// Khai báo tối thiểu — không link framework Preferences, class lấy lúc chạy.
@interface PSSpecifier : NSObject
- (NSString *)name;
- (NSString *)identifier;
- (id)propertyForKey:(id)key;
- (void)setProperty:(id)property forKey:(id)key;
- (void)setButtonAction:(SEL)action;
@end

@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (id)specifier;
- (UITableView *)table;
- (NSIndexPath *)indexPathForSpecifier:(id)specifier;
- (void)reloadSpecifiers;
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
@end

#pragma mark - Prefs

static NSDictionary *gPrefs = nil;

static BOOL AIPSettingsButtonsEnabled(void) {
    return AIPPrefEnabled(gPrefs, @"settingsButtons", YES);
}

// Tên class thật của khu vực Dung lượng trên iOS 16.3.1 (theo log máy thật).
static NSString * const AIPDetailControllerClass = @"STStorageAppDetailController";
static NSString * const AIPListControllerClass = @"STStorageAppsController";
static NSString * const AIPOverviewControllerClass = @"STStorageController";
static NSString * const AIPStorageAppClass = @"STStorageApp";

// Khai báo trước cho các hàm định nghĩa ở phần sau của file.
static NSArray *AIPRawSpecifiers(id controller);
static void AIPScanAndHookStorageClasses(void);

#pragma mark - Tiện ích khớp chữ

static BOOL AIPTextContainsAny(NSString *text, NSArray<NSString *> *needles) {
    if (text.length == 0) return NO;
    NSString *lower = [text lowercaseString];
    for (NSString *needle in needles) {
        if ([lower containsString:needle]) return YES;
    }
    return NO;
}

#pragma mark - Bóc đối tượng dữ liệu của app (STStorageApp)

// Lấy chuỗi từ một object qua danh sách selector, trả chuỗi đầu tiên có nội dung.
static NSString *AIPStringFromObjectViaSelectors(id object, NSArray<NSString *> *selectors) {
    if (!object) return nil;
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([object respondsToSelector:selector]) {
            NSString *value = ((NSString *(*)(id, SEL))objc_msgSend)(object, selector);
            if ([value isKindOfClass:[NSString class]] && value.length > 0) return value;
        }
    }
    return nil;
}

static BOOL AIPIsStorageAppObject(id object) {
    if (!object) return NO;
    Class storageAppClass = NSClassFromString(AIPStorageAppClass);
    if (storageAppClass && [object isKindOfClass:storageAppClass]) return YES;
    return [NSStringFromClass([object class]) isEqualToString:AIPStorageAppClass];
}

// Mã app từ object STStorageApp: thử các selector hay gặp; nếu object bọc
// một proxy app ở trong thì bóc thêm một lớp nữa.
static NSString *AIPBundleIDFromStorageAppObject(id object) {
    if (!object) return nil;
    NSString *bid = AIPStringFromObjectViaSelectors(object, @[@"bundleIdentifier", @"appIdentifier", @"bundleID", @"applicationIdentifier", @"identifier"]);
    if (bid.length > 0) return bid;
    for (NSString *wrapperSelector in @[@"applicationProxy", @"appProxy", @"proxy", @"appRecord", @"record", @"application"]) {
        SEL selector = NSSelectorFromString(wrapperSelector);
        if ([object respondsToSelector:selector]) {
            id inner = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (inner && inner != object) {
                bid = AIPStringFromObjectViaSelectors(inner, @[@"bundleIdentifier", @"appIdentifier", @"bundleID", @"applicationIdentifier", @"identifier"]);
                if (bid.length > 0) return bid;
            }
        }
    }
    return nil;
}

static NSString *AIPNameFromStorageAppObject(id object) {
    if (!object) return nil;
    return AIPStringFromObjectViaSelectors(object, @[@"name", @"localizedName", @"displayName", @"appName"]);
}

// Tìm object STStorageApp nấp trong một giá trị bất kỳ (chính nó, hoặc nằm
// trong dictionary ở một lớp). Trả nil nếu không thấy.
static id AIPUnwrapStorageApp(id value) {
    if (!value) return nil;
    if (AIPIsStorageAppObject(value)) return value;
    if ([value isKindOfClass:[NSDictionary class]]) {
        for (id inner in [(NSDictionary *)value allValues]) {
            if (AIPIsStorageAppObject(inner)) return inner;
        }
    }
    return nil;
}

#pragma mark - Dò mã app từ specifier

static NSString *AIPStringFromObject(id object) {
    if ([object isKindOfClass:[NSString class]]) return (NSString *)object;
    if ([object isKindOfClass:[NSNumber class]]) return [(NSNumber *)object stringValue];
    return nil;
}

static NSString *AIPBundleIDFromObject(id object) {
    NSString *direct = AIPStringFromObject(object);
    if (direct.length > 0 && [direct containsString:@"."] && ![direct containsString:@" "]) return direct;
    id storageApp = AIPUnwrapStorageApp(object);
    if (storageApp) {
        NSString *bid = AIPBundleIDFromStorageAppObject(storageApp);
        if (bid.length > 0) return bid;
    }
    if (object) {
        NSString *bid = AIPStringFromObjectViaSelectors(object, @[@"bundleIdentifier", @"applicationIdentifier", @"appIdentifier", @"bundleID"]);
        if (bid.length > 0) return bid;
    }
    return nil;
}

static NSString *AIPSpecifierName(id specifier) {
    if ([specifier respondsToSelector:@selector(name)]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(specifier, @selector(name));
    }
    return nil;
}

static NSString *AIPSpecifierIdentifier(id specifier) {
    if ([specifier respondsToSelector:@selector(identifier)]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(specifier, @selector(identifier));
    }
    return nil;
}

static id AIPSpecifierProperty(id specifier, NSString *key) {
    if ([specifier respondsToSelector:@selector(propertyForKey:)]) {
        return ((id (*)(id, SEL, id))objc_msgSend)(specifier, @selector(propertyForKey:), key);
    }
    return nil;
}

static NSString *AIPBundleIDFromSpecifier(id specifier) {
    NSString *bid = AIPBundleIDFromObject(AIPSpecifierIdentifier(specifier));
    if (bid.length > 0) return bid;
    id userInfo = AIPSpecifierProperty(specifier, @"userInfo");
    bid = AIPBundleIDFromObject(userInfo);
    if (bid.length > 0) return bid;
    if ([userInfo isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)userInfo allValues]) {
            bid = AIPBundleIDFromObject(value);
            if (bid.length > 0) return bid;
        }
    }
    // Các khoá property hay gặp trên specifier của trang danh sách/dung lượng.
    for (NSString *key in @[@"storageApp", @"app", @"application", @"appProxy", @"applicationProxy", @"appObject", @"representedObject", @"target", @"object", @"bundleIdentifier", @"bundleID", @"applicationIdentifier", @"appIdentifier"]) {
        bid = AIPBundleIDFromObject(AIPSpecifierProperty(specifier, key));
        if (bid.length > 0) return bid;
    }
    return nil;
}

// Một dòng trong danh sách có phải là app đang cần không: so mã app trước,
// không có mã thì so tên hiển thị (tên lấy từ object dữ liệu hoặc từ dòng).
static BOOL AIPSpecifierMatchesApp(id specifier, NSString *bundleID, NSString *appName) {
    NSString *bid = AIPBundleIDFromSpecifier(specifier);
    if (bid.length > 0) return [bid isEqualToString:bundleID];
    id userInfo = AIPSpecifierProperty(specifier, @"userInfo");
    id storageApp = AIPUnwrapStorageApp(userInfo);
    if (!storageApp) {
        for (NSString *key in @[@"storageApp", @"app", @"application", @"appObject", @"representedObject", @"object"]) {
            storageApp = AIPUnwrapStorageApp(AIPSpecifierProperty(specifier, key));
            if (storageApp) break;
        }
    }
    if (storageApp) {
        NSString *name = AIPNameFromStorageAppObject(storageApp);
        if (name.length > 0 && appName.length > 0) return [name isEqualToString:appName];
    }
    NSString *name = AIPSpecifierName(specifier);
    if (name.length > 0 && appName.length > 0) return [name isEqualToString:appName];
    return NO;
}

#pragma mark - Dò mã app từ controller

static PSSpecifier *AIPParentSpecifierOfController(id controller) {
    if ([controller respondsToSelector:@selector(parentSpecifier)]) {
        return ((PSSpecifier *(*)(id, SEL))objc_msgSend)(controller, @selector(parentSpecifier));
    }
    return nil;
}

// Quét các biến nội bộ (ivar) của controller tìm object STStorageApp —
// controller trang chi tiết gần như chắc chắn giữ app của nó trong ivar.
static NSString *AIPBundleIDFromControllerIvars(id controller) {
    if (!controller) return nil;
    NSString *found = nil;
    @try {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([controller class], &count);
        if (ivars) {
            for (unsigned int i = 0; i < count && found.length == 0; i++) {
                const char *encoding = ivar_getTypeEncoding(ivars[i]);
                if (!encoding || encoding[0] != '@') continue;
                id value = object_getIvar(controller, ivars[i]);
                if (AIPIsStorageAppObject(value)) {
                    found = AIPBundleIDFromStorageAppObject(value);
                }
            }
            free(ivars);
        }
    } @catch (NSException *exception) {
        AIPLog(@"Quet ivar cua %@ loi: %@", NSStringFromClass([controller class]), exception.name);
    }
    return found;
}

static NSString *AIPBundleIDFromController(id controller, NSArray *specifiers) {
    if (!controller) return nil;
    // 1) Controller tự khai app của nó qua selector.
    for (NSString *selectorName in @[@"storageApp", @"app", @"application", @"appProxy", @"applicationProxy", @"currentApp", @"representedApp"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([controller respondsToSelector:selector]) {
            id object = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
            NSString *bid = AIPBundleIDFromObject(object);
            if (bid.length > 0) return bid;
        }
    }
    for (NSString *selectorName in @[@"bundleIdentifier", @"applicationIdentifier", @"appIdentifier", @"bundleID"]) {
        NSString *bid = AIPStringFromObjectViaSelectors(controller, @[selectorName]);
        if (bid.length > 0) return bid;
    }
    // 2) Quét ivar tìm STStorageApp.
    NSString *bid = AIPBundleIDFromControllerIvars(controller);
    if (bid.length > 0) return bid;
    // 3) Specifier cha (trang danh sách truyền xuống khi mở trang chi tiết).
    PSSpecifier *parent = AIPParentSpecifierOfController(controller);
    if (parent) {
        bid = AIPBundleIDFromSpecifier(parent);
        if (bid.length > 0) return bid;
        NSString *parentID = AIPSpecifierIdentifier(parent);
        if (parentID.length > 0 && [parentID containsString:@"."] && ![parentID containsString:@" "]) return parentID;
        id userInfo = AIPSpecifierProperty(parent, @"userInfo");
        bid = AIPBundleIDFromObject(userInfo);
        if (bid.length > 0) return bid;
    }
    // 4) Quét chính các specifier của trang.
    NSArray *specs = specifiers;
    if (!specs) specs = AIPRawSpecifiers(controller);
    for (id specifier in specs ?: @[]) {
        bid = AIPBundleIDFromSpecifier(specifier);
        if (bid.length > 0) return bid;
    }
    // 5) Khớp theo tiêu đề trang với tên app.
    NSString *title = nil;
    if ([controller isKindOfClass:[UIViewController class]]) title = [(UIViewController *)controller title];
    if (title.length > 0) {
        NSArray *all = nil;
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (wsClass) {
            id workspace = ((id (*)(id, SEL))objc_msgSend)(wsClass, @selector(defaultWorkspace));
            if ([workspace respondsToSelector:@selector(allApplications)]) {
                all = ((NSArray *(*)(id, SEL))objc_msgSend)(workspace, @selector(allApplications));
            }
        }
        for (id proxy in all ?: @[]) {
            NSString *name = AIPStringFromObjectViaSelectors(proxy, @[@"localizedName"]);
            if (name.length > 0 && [name isEqualToString:title]) {
                NSString *proxyBID = AIPStringFromObjectViaSelectors(proxy, @[@"applicationIdentifier", @"bundleIdentifier"]);
                if (proxyBID.length > 0) return proxyBID;
            }
        }
    }
    return nil;
}

#pragma mark - Ghi log hình dạng trang (để chẩn đoán)

static NSMutableDictionary<NSString *, NSNumber *> *gDumpedCounts = nil;

// In danh sách specifier của 2 trang quan trọng mỗi khi SỐ LƯỢNG của chúng
// thay đổi (trang danh sách lúc mới mở báo 0 mục, nạp đủ mới có app).
static void AIPDumpSpecifiersIfChanged(id controller, NSArray *specifiers) {
    NSString *className = NSStringFromClass([controller class]);
    BOOL isKeyPage = [className isEqualToString:AIPListControllerClass] || [className isEqualToString:AIPDetailControllerClass];
    if (!gDumpedCounts) gDumpedCounts = [NSMutableDictionary dictionary];
    if (!isKeyPage) {
        BOOL interesting = [className containsString:@"Storage"];
        if (!interesting) {
            for (id specifier in specifiers ?: @[]) {
                NSString *name = AIPSpecifierName(specifier);
                NSString *identifier = AIPSpecifierIdentifier(specifier);
                if (AIPTextContainsAny(name, @[@"offload", @"gỡ bỏ", @"delete", @"xoá", @"xóa"]) ||
                    AIPTextContainsAny(identifier, @[@"offload", @"delete"])) { interesting = YES; break; }
            }
        }
        if (!interesting) return;
        if (gDumpedCounts[className]) return;
        gDumpedCounts[className] = @(-1);
    } else {
        NSNumber *last = gDumpedCounts[className];
        if (last && [last integerValue] == (NSInteger)specifiers.count) return;
        gDumpedCounts[className] = @(specifiers.count);
    }
    NSMutableString *dump = [NSMutableString stringWithFormat:@"Trang %@ (%lu specifiers):", className, (unsigned long)specifiers.count];
    NSUInteger limit = MIN(specifiers.count, (NSUInteger)60);
    for (NSUInteger i = 0; i < limit; i++) {
        id specifier = specifiers[i];
        NSInteger cellType = -2;
        if ([specifier respondsToSelector:@selector(cellType)]) {
            cellType = ((NSInteger (*)(id, SEL))objc_msgSend)(specifier, @selector(cellType));
        }
        NSString *extra = @"";
        id storageApp = AIPUnwrapStorageApp(AIPSpecifierProperty(specifier, @"userInfo"));
        if (storageApp) {
            NSString *bid = AIPBundleIDFromStorageAppObject(storageApp);
            extra = [NSString stringWithFormat:@" app=%@", bid ?: @"?"];
        }
        [dump appendFormat:@"\n  - name='%@' id='%@' cell=%ld%@", AIPSpecifierName(specifier) ?: @"", AIPSpecifierIdentifier(specifier) ?: @"", (long)cellType, extra];
    }
    AIPLog(@"%@", dump);
}

#pragma mark - Nhận diện trang chi tiết

static BOOL AIPIsDetailClassName(NSString *className) {
    return [className isEqualToString:AIPDetailControllerClass] ||
           ([className containsString:@"Storage"] && [className containsString:@"AppDetail"]);
}

static BOOL AIPIsStorageDetailPage(id controller, NSArray *specifiers, BOOL *hasOffload, BOOL *hasDelete) {
    BOOL offload = NO, delete = NO, size = NO;
    for (id specifier in specifiers ?: @[]) {
        NSString *name = AIPSpecifierName(specifier);
        NSString *identifier = AIPSpecifierIdentifier(specifier);
        if (AIPTextContainsAny(name, @[@"offload", @"gỡ bỏ ứng dụng", @"gỡ bỏ"]) ||
            AIPTextContainsAny(identifier, @[@"offload"])) offload = YES;
        if (AIPTextContainsAny(name, @[@"delete app", @"xoá ứng dụng", @"xóa ứng dụng", @"delete"]) ||
            AIPTextContainsAny(identifier, @[@"delete"])) delete = YES;
        if (AIPTextContainsAny(name, @[@"app size", @"documents & data", @"kích thước", @"dung lượng app", @"tài liệu"]) ||
            AIPTextContainsAny(identifier, @[@"size", @"documents"])) size = YES;
    }
    if (hasOffload) *hasOffload = offload;
    if (hasDelete) *hasDelete = delete;
    if (AIPIsDetailClassName(NSStringFromClass([controller class]))) return YES;
    return (offload && delete) || (offload && size) || (size && delete);
}

#pragma mark - Hành động của 2 nút (chạy ngay trong Cài đặt)

static void AIPPresentAlertFromController(id controller, NSString *title, NSString *message) {
    UIViewController *presenter = nil;
    if ([controller isKindOfClass:[UIViewController class]]) presenter = (UIViewController *)controller;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter || !presenter.view.window) {
        AIPLog(@"Khong co noi hien hop thoai: %@ — %@", title, message);
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void AIPHandleClearCache(id controller) {
    NSString *bundleID = AIPBundleIDFromController(controller, nil);
    if (!bundleID) {
        AIPLog(@"Nut Clear Cache: khong do duoc ma app tu trang chi tiet");
        AIPPresentAlertFromController(controller, @"Không xác định được app", @"Không đọc được mã ứng dụng của trang này nên chưa xoá được bộ nhớ đệm.");
        return;
    }
    NSString *appName = AIPAppNameForBundleID(bundleID, bundleID.lastPathComponent);
    UIViewController *presenter = [controller isKindOfClass:[UIViewController class]] ? (UIViewController *)controller : nil;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear App's Cache"
        message:[NSString stringWithFormat:@"Xoá bộ nhớ đệm (cache) của %@? Tài liệu và đăng nhập vẫn giữ nguyên.", appName]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xoá" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            long long freed = AIPClearCacheForBundleID(bundleID);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (freed < 0) {
                    AIPPresentAlertFromController(controller, @"Chưa xoá được", @"Không tìm thấy thư mục dữ liệu của app.");
                } else {
                    AIPLog(@"Da xoa cache cua %@ tu trang dung luong: ~%lld byte", bundleID, freed);
                    AIPPresentAlertFromController(controller, @"Đã xoá bộ nhớ đệm", [NSString stringWithFormat:@"%@ — giải phóng khoảng %@.", appName, AIPByteString((unsigned long long)freed)]);
                }
            });
        });
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void AIPHandleResetApp(id controller) {
    NSString *bundleID = AIPBundleIDFromController(controller, nil);
    if (!bundleID) {
        AIPLog(@"Nut Reset App: khong do duoc ma app tu trang chi tiet");
        AIPPresentAlertFromController(controller, @"Không xác định được app", @"Không đọc được mã ứng dụng của trang này nên chưa đặt lại được.");
        return;
    }
    NSString *appName = AIPAppNameForBundleID(bundleID, bundleID.lastPathComponent);
    UIViewController *presenter = [controller isKindOfClass:[UIViewController class]] ? (UIViewController *)controller : nil;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;
    UIAlertController *first = [UIAlertController alertControllerWithTitle:@"Reset App"
        message:[NSString stringWithFormat:@"Đặt lại %@ về như mới cài? Toàn bộ dữ liệu trong app (tài khoản, tài liệu, cài đặt riêng) sẽ bị xoá sạch. App vẫn còn trên máy.", appName]
        preferredStyle:UIAlertControllerStyleAlert];
    [first addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [first addAction:[UIAlertAction actionWithTitle:@"Tiếp tục" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        UIAlertController *second = [UIAlertController alertControllerWithTitle:@"Chắc chắn đặt lại?"
            message:[NSString stringWithFormat:@"Xoá sạch dữ liệu của %@ — không khôi phục được.", appName]
            preferredStyle:UIAlertControllerStyleAlert];
        [second addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
        [second addAction:[UIAlertAction actionWithTitle:@"Đặt lại" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action2) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                long long freed = AIPResetDataForBundleID(bundleID);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (freed < 0) {
                        AIPPresentAlertFromController(controller, @"Chưa đặt lại được", @"Không tìm thấy thư mục dữ liệu của app.");
                    } else {
                        AIPLog(@"Da dat lai %@ tu trang dung luong: ~%lld byte", bundleID, freed);
                        AIPPresentAlertFromController(controller, @"Đã đặt lại app", [NSString stringWithFormat:@"%@ đã về trạng thái như mới cài.", appName]);
                    }
                });
            });
        }]];
        UIViewController *presenter2 = [controller isKindOfClass:[UIViewController class]] ? (UIViewController *)controller : nil;
        while (presenter2.presentedViewController) presenter2 = presenter2.presentedViewController;
        [presenter2 presentViewController:second animated:YES completion:nil];
    }]];
    [presenter presentViewController:first animated:YES completion:nil];
}

// Hai hàm này được gắn thẳng vào class PSListController (class_addMethod ở
// phần cài hook) để nút bấm trên trang gọi tới — đúng mẫu CacheClearer vẫn dùng.
static void AIPClearCacheButtonAction(id self, SEL _cmd, id specifier) {
    AIPHandleClearCache(self);
}

static void AIPResetAppButtonAction(id self, SEL _cmd, id specifier) {
    AIPHandleResetApp(self);
}

#pragma mark - Tạo 2 nút dạng specifier

static PSSpecifier *AIPMakeButtonSpecifier(NSString *title, SEL action, NSInteger cellType, id target, NSString *kind) {
    Class specifierClass = NSClassFromString(@"PSSpecifier");
    if (!specifierClass) return nil;
    SEL factory = @selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:);
    if (![specifierClass respondsToSelector:factory]) return nil;
    PSSpecifier *specifier = ((PSSpecifier *(*)(id, SEL, id, id, SEL, SEL, Class, NSInteger, SEL))objc_msgSend)(specifierClass, factory, title, target, NULL, NULL, Nil, cellType, NULL);
    if (!specifier) return nil;
    [specifier setButtonAction:action];
    [specifier setProperty:kind forKey:@"AIPKind"];
    [specifier setProperty:@YES forKey:@"AIPButton"];
    return specifier;
}

static BOOL AIPSpecifiersContainKind(NSArray *specifiers, NSString *kind) {
    for (id specifier in specifiers ?: @[]) {
        id value = AIPSpecifierProperty(specifier, @"AIPKind");
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value isEqualToString:kind]) return YES;
    }
    return NO;
}

// Kiểu ô cho 2 nút mới: mượn kiểu của mục cuối trang (trên trang chi tiết,
// mục cuối chính là nút Xoá ứng dụng) để nút hiện đúng dáng nút bấm gốc.
static NSInteger AIPCellTypeForNewButtons(NSArray *specifiers) {
    for (NSInteger i = (NSInteger)specifiers.count - 1; i >= 0; i--) {
        id specifier = specifiers[(NSUInteger)i];
        if ([specifier respondsToSelector:@selector(cellType)]) {
            NSInteger cellType = ((NSInteger (*)(id, SEL))objc_msgSend)(specifier, @selector(cellType));
            if (cellType > 0) return cellType;
        }
    }
    return 8; // PSButtonCell theo header Preferences kinh điển
}

#pragma mark - Yêu cầu nhảy trang đang chờ (phía SpringBoard ghi vào prefs)

static NSString *AIPPendingBundleID(NSTimeInterval *ageOut) {
    NSDictionary *prefs = AIPLoadPrefs();
    NSString *bundleID = prefs[@"pendingStorageApp"];
    NSNumber *at = prefs[@"pendingStorageAt"];
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) return nil;
    NSTimeInterval age = at ? ([[NSDate date] timeIntervalSince1970] - [at doubleValue]) : 9999;
    if (ageOut) *ageOut = age;
    return age <= 30 ? bundleID : nil;
}

static void AIPClearPending(void) {
    AIPSetPrefValue(@"pendingStorageApp", nil);
    AIPSetPrefValue(@"pendingStorageAt", nil);
}

#pragma mark - Chạm vào một dòng trong trang danh sách

static BOOL AIPSelectSpecifier(id controller, id specifier) {
    @try {
        if (![controller respondsToSelector:@selector(indexPathForSpecifier:)] ||
            ![controller respondsToSelector:@selector(table)]) return NO;
        NSIndexPath *indexPath = ((NSIndexPath *(*)(id, SEL, id))objc_msgSend)(controller, @selector(indexPathForSpecifier:), specifier);
        if (!indexPath) return NO;
        UITableView *table = ((UITableView *(*)(id, SEL))objc_msgSend)(controller, @selector(table));
        if (table) [table scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        if ([controller respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(controller, @selector(tableView:didSelectRowAtIndexPath:), table, indexPath);
            return YES;
        }
    } @catch (NSException *exception) {
        AIPLog(@"Chon dong trong danh sach loi: %@", exception.name);
    }
    return NO;
}

// Thử nhảy ngay bằng chính danh sách specifier vừa chạy qua hook.
static void AIPTryJumpWithSpecifiers(id controller, NSArray *specifiers) {
    NSTimeInterval age = 0;
    NSString *bundleID = AIPPendingBundleID(&age);
    if (!bundleID || specifiers.count == 0) return;
    NSString *appName = AIPAppNameForBundleID(bundleID, nil);
    for (id specifier in specifiers) {
        if (AIPSpecifierMatchesApp(specifier, bundleID, appName)) {
            if (AIPSelectSpecifier(controller, specifier)) {
                AIPLog(@"Dung luong: da tu nhay vao app %@ tu trang danh sach", bundleID);
                AIPClearPending();
            }
            return;
        }
    }
}

#pragma mark - Hook -specifiers (theo từng class)

static NSMutableDictionary<NSString *, NSValue *> *gSpecOriginals = nil;
static __weak id gAppsListController = nil;
static __weak id gLastStorageListController = nil;

static IMP AIPOriginalForClass(Class cls) {
    if (!cls || !gSpecOriginals) return NULL;
    Class current = cls;
    while (current) {
        NSValue *value = gSpecOriginals[NSStringFromClass(current)];
        if (value) return (IMP)[value pointerValue];
        current = class_getSuperclass(current);
    }
    return NULL;
}

static NSArray *AIPRawSpecifiers(id controller) {
    if (!controller) return nil;
    IMP orig = AIPOriginalForClass([controller class]);
    if (orig) return ((NSArray *(*)(id, SEL))orig)(controller, @selector(specifiers));
    if ([controller respondsToSelector:@selector(specifiers)]) {
        return ((NSArray *(*)(id, SEL))objc_msgSend)(controller, @selector(specifiers));
    }
    return nil;
}

static NSArray *AIPProcessSpecifiers(id controller, NSArray *specifiers) {
    if (!specifiers) return specifiers;
    @try {
        AIPScanAndHookStorageClasses();
        NSString *className = NSStringFromClass([controller class]);
        AIPDumpSpecifiersIfChanged(controller, specifiers);
        BOOL hasOffload = NO, hasDelete = NO;
        BOOL detail = AIPIsStorageDetailPage(controller, specifiers, &hasOffload, &hasDelete);
        if (detail) {
            NSString *bundleID = AIPBundleIDFromController(controller, specifiers);
            static NSString *lastLoggedDetailApp = nil;
            if (bundleID.length > 0 && ![bundleID isEqualToString:lastLoggedDetailApp]) {
                lastLoggedDetailApp = [bundleID copy];
                AIPLog(@"Trang dung luong cua app: %@ (class %@)", bundleID, className);
            }
            NSTimeInterval age = 0;
            NSString *pending = AIPPendingBundleID(&age);
            if (pending.length > 0 && bundleID.length > 0 && [pending isEqualToString:bundleID]) {
                AIPLog(@"Dung luong: dang o san trang cua app %@, xong", bundleID);
                AIPClearPending();
            }
            if (AIPSettingsButtonsEnabled() &&
                !AIPSpecifiersContainKind(specifiers, @"clear") &&
                !AIPSpecifiersContainKind(specifiers, @"reset")) {
                NSInteger cellType = AIPCellTypeForNewButtons(specifiers);
                PSSpecifier *clear = AIPMakeButtonSpecifier(@"Clear App's Cache", @selector(aip_clearCacheButtonTapped:), cellType, controller, @"clear");
                PSSpecifier *reset = AIPMakeButtonSpecifier(@"Reset App", @selector(aip_resetAppButtonTapped:), cellType, controller, @"reset");
                if (clear && reset) {
                    NSMutableArray *extended = [specifiers mutableCopy];
                    [extended addObject:clear];
                    [extended addObject:reset];
                    AIPLog(@"Trang %@: da them 2 nut Reset/Clear (app %@, cellType %ld)", className, bundleID ?: @"chua ro", (long)cellType);
                    return [extended copy];
                }
                AIPLog(@"Trang %@: tao 2 nut that bai", className);
            }
            return specifiers;
        }
        if ([className isEqualToString:AIPListControllerClass]) {
            gAppsListController = controller;
            AIPTryJumpWithSpecifiers(controller, specifiers);
        } else if ([className containsString:@"Storage"] && ![className containsString:@"Detail"]) {
            gLastStorageListController = controller;
            AIPTryJumpWithSpecifiers(controller, specifiers);
        }
    } @catch (NSException *exception) {
        AIPLog(@"Xu ly specifiers cua %@ loi: %@", NSStringFromClass([controller class]), exception.name);
    }
    return specifiers;
}

static NSArray *AIPSpecifiersHookGeneric(id self, SEL _cmd) {
    IMP orig = AIPOriginalForClass([self class]);
    NSArray *specifiers = orig ? ((NSArray *(*)(id, SEL))orig)(self, _cmd) : nil;
    return AIPProcessSpecifiers(self, specifiers);
}

#pragma mark - Bộ theo dõi nhảy trang (dò nhanh 0.15s/lần)

static void AIPCollectControllers(UIViewController *root, NSMutableArray *into) {
    if (!root || [into containsObject:root]) return;
    [into addObject:root];
    if ([root isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in [(UINavigationController *)root viewControllers]) {
            AIPCollectControllers(child, into);
        }
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in [(UITabBarController *)root viewControllers]) {
            AIPCollectControllers(child, into);
        }
    }
    if (root.presentedViewController) AIPCollectControllers(root.presentedViewController, into);
    for (UIViewController *child in root.childViewControllers) {
        AIPCollectControllers(child, into);
    }
}

static NSMutableArray *AIPAllControllersInPreferences(void) {
    NSMutableArray *all = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            if (window.rootViewController) AIPCollectControllers(window.rootViewController, all);
        }
    }
    return all;
}

static UIViewController *AIPVisibleTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *candidate in windowScene.windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (!window) window = windowScene.windows.firstObject;
        if (window) break;
    }
    UIViewController *top = window.rootViewController;
    for (NSInteger guard = 0; top && guard < 20; guard++) {
        if (top.presentedViewController) { top = top.presentedViewController; continue; }
        if ([top isKindOfClass:[UINavigationController class]]) { top = [(UINavigationController *)top visibleViewController]; continue; }
        if ([top isKindOfClass:[UITabBarController class]]) { top = [(UITabBarController *)top selectedViewController]; continue; }
        break;
    }
    return top;
}

// Tìm trang danh sách app: ưu tiên đúng class STStorageAppsController,
// sau đó tới các controller Storage khác (trừ trang tổng và các trang chi tiết).
static id AIPFindStorageListController(void) {
    NSMutableArray *all = AIPAllControllersInPreferences();
    id overview = nil;
    id other = nil;
    for (UIViewController *controller in all) {
        NSString *className = NSStringFromClass([controller class]);
        if ([className isEqualToString:AIPListControllerClass]) return controller;
        if ([className isEqualToString:AIPOverviewControllerClass]) { overview = controller; continue; }
        if (!other && [className containsString:@"Storage"] && ![className containsString:@"Detail"] &&
            [controller respondsToSelector:@selector(specifiers)]) other = controller;
    }
    return other ?: overview;
}

static NSInteger gJumpAttempts = 0;
static NSString *gLastPendingSeen = nil;

static void AIPAttemptPendingJump(void) {
    NSTimeInterval age = 0;
    NSString *bundleID = AIPPendingBundleID(&age);
    if (!bundleID) { gJumpAttempts = 0; gLastPendingSeen = nil; return; }
    if (![bundleID isEqualToString:gLastPendingSeen]) {
        gLastPendingSeen = [bundleID copy];
        gJumpAttempts = 0;
    }
    gJumpAttempts++;
    BOOL shouldLog = (gJumpAttempts <= 3 || gJumpAttempts % 10 == 0);
    // Đang đứng sẵn ở trang chi tiết của đúng app này rồi thì xong.
    UIViewController *top = AIPVisibleTopController();
    if (top && AIPIsDetailClassName(NSStringFromClass([top class]))) {
        NSString *topBID = AIPBundleIDFromController(top, nil);
        if ([topBID isEqualToString:bundleID]) {
            AIPLog(@"Dung luong: dang o san trang cua app %@, xong", bundleID);
            AIPClearPending();
            gJumpAttempts = 0;
            return;
        }
    }
    id candidate = gAppsListController ?: AIPFindStorageListController() ?: gLastStorageListController;
    if (!candidate) {
        if (shouldLog) AIPLog(@"Dung luong: lan thu %ld — chua thay trang danh sach dung luong", (long)gJumpAttempts);
        return;
    }
    NSArray *specifiers = AIPRawSpecifiers(candidate);
    if (specifiers.count == 0) {
        if (shouldLog) AIPLog(@"Dung luong: lan thu %ld — danh sach dang nap (0 muc)", (long)gJumpAttempts);
        return;
    }
    NSString *appName = AIPAppNameForBundleID(bundleID, nil);
    for (id specifier in specifiers) {
        if (AIPSpecifierMatchesApp(specifier, bundleID, appName)) {
            if (AIPSelectSpecifier(candidate, specifier)) {
                AIPLog(@"Dung luong: da tu nhay vao app %@ (lan thu %ld)", bundleID, (long)gJumpAttempts);
                AIPClearPending();
                gJumpAttempts = 0;
            }
            return;
        }
    }
    if (shouldLog) AIPLog(@"Dung luong: lan thu %ld — %@ co %lu muc, chua thay %@", (long)gJumpAttempts, NSStringFromClass([candidate class]), (unsigned long)specifiers.count, bundleID);
}

static NSTimer *gPendingTimer = nil;

static void AIPEnsurePendingWatcher(void) {
    if (gPendingTimer) return;
    gPendingTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *timer) {
        @try { AIPAttemptPendingJump(); } @catch (NSException *exception) { }
    }];
}

#pragma mark - Cài hook + quét class Storage

static BOOL AIPClassHasOwnMethod(Class cls, SEL selector) {
    if (!cls) return NO;
    BOOL found = NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods) {
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == selector) { found = YES; break; }
        }
        free(methods);
    }
    return found;
}

static void AIPHookSpecifiersForClass(Class cls) {
    if (!cls) return;
    NSString *className = NSStringFromClass(cls);
    if (!gSpecOriginals) gSpecOriginals = [NSMutableDictionary dictionary];
    if (gSpecOriginals[className]) return;
    if (!class_getInstanceMethod(cls, @selector(specifiers))) return;
    IMP orig = NULL;
    MSHookMessageEx(cls, @selector(specifiers), (IMP)AIPSpecifiersHookGeneric, &orig);
    if (orig) {
        gSpecOriginals[className] = [NSValue valueWithPointer:orig];
        AIPLog(@"Cai dat: da hook -specifiers cua %@", className);
    }
}

static IMP gViewWillAppearOriginal = NULL;

static void AIPViewWillAppearHook(id self, SEL _cmd, BOOL animated) {
    if (gViewWillAppearOriginal) {
        ((void (*)(id, SEL, BOOL))gViewWillAppearOriginal)(self, _cmd, animated);
    }
    @try { AIPScanAndHookStorageClasses(); } @catch (NSException *exception) { }
}

// Chỉ ghi các class Storage đáng quan tâm (controller/cell/app) để log gọn.
static void AIPLogStorageClasses(void) {
    static NSString *lastDump = nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (![name containsString:@"Storage"]) continue;
        if (![name containsString:@"Controller"] && ![name containsString:@"Cell"] && ![name containsString:@"App"]) continue;
        Class superclass = class_getSuperclass(classes[i]);
        [names addObject:[NSString stringWithFormat:@"%@ (cha: %@)", name, superclass ? NSStringFromClass(superclass) : @"?"]];
    }
    free(classes);
    [names sortUsingSelector:@selector(compare:)];
    NSString *dump = [names componentsJoinedByString:@", "];
    if (dump.length > 0 && ![dump isEqualToString:lastDump]) {
        lastDump = [dump copy];
        AIPLog(@"Cac class Storage lien quan trong Cai dat: %@", dump);
    }
}

static void AIPScanAndHookStorageClasses(void) {
    static NSTimeInterval lastScan = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastScan < 0.5) return;
    lastScan = now;
    @try {
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (classes) {
            for (unsigned int i = 0; i < count; i++) {
                NSString *name = NSStringFromClass(classes[i]);
                if ([name containsString:@"Storage"] && AIPClassHasOwnMethod(classes[i], @selector(specifiers))) {
                    AIPHookSpecifiersForClass(classes[i]);
                }
            }
            free(classes);
        }
        AIPLogStorageClasses();
    } @catch (NSException *exception) {
        AIPLog(@"Quet class Storage loi: %@", exception.name);
    }
}

static void AIPRegisterButtonActions(Class listClass) {
    BOOL clearOK = class_addMethod(listClass, @selector(aip_clearCacheButtonTapped:), (IMP)AIPClearCacheButtonAction, "v@:@");
    BOOL resetOK = class_addMethod(listClass, @selector(aip_resetAppButtonTapped:), (IMP)AIPResetAppButtonAction, "v@:@");
    AIPLog(@"Cai dat: gan hanh dong 2 nut vao PSListController (clear=%@, reset=%@)", clearOK ? @"OK" : @"co san/khong duoc", resetOK ? @"OK" : @"co san/khong duoc");
}

static void AIPInstallHook(NSInteger attempt) {
    Class listClass = NSClassFromString(@"PSListController");
    if (!listClass) {
        if (attempt < 5) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                AIPInstallHook(attempt + 1);
            });
        } else {
            AIPLog(@"Cai dat: KHONG thay PSListController, bo cuoc");
        }
        return;
    }
    AIPHookSpecifiersForClass(listClass);
    if (!gViewWillAppearOriginal) {
        MSHookMessageEx(listClass, @selector(viewWillAppear:), (IMP)AIPViewWillAppearHook, &gViewWillAppearOriginal);
    }
    AIPRegisterButtonActions(listClass);
    AIPScanAndHookStorageClasses();
    AIPLog(@"Cai dat: da cai hook xong (PSListController + quet class Storage)");
}

// Timer quét đều trong lúc Cài đặt mới mở, để móc được các class Storage
// ngay khi gói của chúng nạp (trước khi người dùng kịp mở trang chi tiết).
static NSTimer *gScanTimer = nil;
static NSInteger gScanTicks = 0;

static void AIPStartScanTimer(void) {
    if (gScanTimer) return;
    gScanTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        gScanTicks++;
        AIPScanAndHookStorageClasses();
        BOOL detailHooked = gSpecOriginals[AIPDetailControllerClass] != nil;
        if (detailHooked || gScanTicks >= 120) {
            [timer invalidate];
            gScanTimer = nil;
            AIPLog(@"Cai dat: dung timer quet (da hook trang chi tiet: %@, sau %ld lan)", detailHooked ? @"ROI" : @"CHUA", (long)gScanTicks);
        }
    }];
}

#pragma mark - Khởi động

static void AIPPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    gPrefs = AIPLoadPrefs();
}

%ctor {
    gPrefs = AIPLoadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, AIPPrefsChangedCallback, (__bridge CFStringRef)AIPPrefsChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    AIPLog(@"AppInfoPress (Cai dat) da nap — enabled=%@, settingsButtons=%@", AIPPrefEnabled(gPrefs, @"enabled", YES) ? @"YES" : @"NO", AIPSettingsButtonsEnabled() ? @"YES" : @"NO");
    AIPInstallHook(0);
    AIPEnsurePendingWatcher();
    dispatch_async(dispatch_get_main_queue(), ^{
        AIPStartScanTimer();
    });
}
