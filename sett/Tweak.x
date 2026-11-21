// AppInfoPress (phần Cài đặt) — com.anhdang.appinfopress
// Hai việc trong app Cài đặt:
//   1) Thêm 2 nút "Đặt lại app" + "Xoá bộ nhớ đệm của app" vào trang dung lượng
//      của từng app (Cài đặt chung -> Dung lượng iPhone -> app), kiểu CacheClearer.
//   2) Khi phía SpringBoard xin mở trang dung lượng của 1 app cụ thể, tự nhảy tiếp
//      từ danh sách dung lượng vào đúng app đó.
// Bản 1.0.1: bản 1.0.0 không hiện nút trên máy thật. Ba hướng sửa:
//   - Hook -specifiers không chỉ ở lớp cha PSListController mà quét và hook riêng
//     từng class chứa "Storage" (các class này nạp muộn, nên quét lại nhiều lần).
//   - Nhận diện trang chi tiết nới lỏng: chỉ cần cặp Gỡ bỏ + Xoá là đủ (bản cũ đòi
//     thêm dòng dung lượng — mà dòng đó trên iOS 16 nằm ở phần đầu trang tự vẽ,
//     không phải specifier, nên không bao giờ khớp).
//   - Khâu tự nhảy vào app: thử lại nhiều lần bằng bộ theo dõi nền thay vì thử
//     đúng một lần sau 0.4 giây (danh sách dung lượng nạp app dần dần).
// Mọi hook đều bọc @try, lỗi ở đâu cũng bỏ qua êm, không làm sập Cài đặt.

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

@interface AIPSettingsHelper : NSObject
+ (instancetype)sharedHelper;
- (void)aipClearCacheTapped:(id)specifier;
- (void)aipResetTapped:(id)specifier;
- (NSString *)bundleIDFromSpecifier:(id)specifier;
- (void)showMessage:(NSString *)message;
- (void)reloadDetailPage;
@end

static __weak id gDetailController = nil;
static __weak id gLastStorageListController = nil;
static NSMutableDictionary<NSString *, NSValue *> *gSpecOriginals = nil;
static int gJumpAttemptCount = 0;

#pragma mark - Tiện ích

static UIViewController *AIPSettingsTopViewController(void) {
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
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]]) top = [(UINavigationController *)top topViewController];
    return top;
}

static NSString *AIPLower(id object) {
    if ([object isKindOfClass:[NSString class]]) return [(NSString *)object lowercaseString];
    return @"";
}

static BOOL AIPTextMatches(NSString *text, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([text containsString:needle]) return YES;
    }
    return NO;
}

static NSString *AIPBundleIDFromObject(id object) {
    if ([object isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)object;
        if ([string containsString:@"."] && ![string containsString:@" "]) return string;
        return nil;
    }
    if (!object) return nil;
    if ([object respondsToSelector:@selector(applicationIdentifier)]) {
        NSString *bid = ((NSString *(*)(id, SEL))objc_msgSend)(object, @selector(applicationIdentifier));
        if (bid.length > 0) return bid;
    }
    if ([object respondsToSelector:@selector(bundleIdentifier)]) {
        NSString *bid = ((NSString *(*)(id, SEL))objc_msgSend)(object, @selector(bundleIdentifier));
        if (bid.length > 0) return bid;
    }
    return nil;
}

static NSString *AIPBundleIDForAppName(NSString *appName) {
    if (appName.length == 0) return nil;
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) return nil;
    id workspace = ((id (*)(id, SEL))objc_msgSend)(wsClass, @selector(defaultWorkspace));
    if (!workspace) return nil;
    NSArray *proxies = ((NSArray *(*)(id, SEL))objc_msgSend)(workspace, @selector(allInstalledApplications));
    for (id proxy in proxies ?: @[]) {
        @try {
            NSString *name = nil;
            if ([proxy respondsToSelector:@selector(localizedName)]) name = ((NSString *(*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName));
            if ([name isEqualToString:appName]) {
                NSString *bid = AIPBundleIDFromObject(proxy);
                if (bid) return bid;
            }
        } @catch (NSException *exception) {}
    }
    return nil;
}

// Tìm bundle id của app mà trang chi tiết đang hiển thị.
// Thứ tự dò: chính controller -> specifier cha (identifier / userInfo /
// property) -> khớp tên app.
static NSString *AIPResolveDetailBundleID(id controller) {
    if (!controller) return nil;
    NSArray<NSString *> *controllerSelectors = @[@"applicationProxy", @"application", @"appProxy", @"storageApp", @"bundleIdentifier", @"applicationIdentifier"];
    for (NSString *selName in controllerSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([controller respondsToSelector:sel]) {
            @try {
                id value = ((id (*)(id, SEL))objc_msgSend)(controller, sel);
                NSString *bid = AIPBundleIDFromObject(value);
                if (bid) return bid;
            } @catch (NSException *exception) {}
        }
    }
    id parent = nil;
    if ([controller respondsToSelector:@selector(specifier)]) {
        parent = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(specifier));
    }
    if (parent) {
        NSString *bid = AIPBundleIDFromObject([parent respondsToSelector:@selector(identifier)] ? [parent identifier] : nil);
        if (bid) return bid;
        if ([parent respondsToSelector:@selector(userInfo)]) {
            NSDictionary *info = ((NSDictionary *(*)(id, SEL))objc_msgSend)(parent, @selector(userInfo));
            if ([info isKindOfClass:[NSDictionary class]]) {
                static NSMutableSet<NSString *> *loggedControllers = nil;
                if (!loggedControllers) loggedControllers = [NSMutableSet set];
                NSString *pointerKey = [NSString stringWithFormat:@"%p", controller];
                if (![loggedControllers containsObject:pointerKey]) {
                    [loggedControllers addObject:pointerKey];
                    AIPLog(@"Trang dung luong: userInfo cua specifier cha co cac khoa: %@", [info allKeys]);
                }
                for (id key in info) {
                    bid = AIPBundleIDFromObject(info[key]);
                    if (bid) return bid;
                }
            }
        }
        if ([parent respondsToSelector:@selector(propertyForKey:)]) {
            for (NSString *key in @[@"application", @"app", @"bundleIdentifier", @"bundleID", @"applicationIdentifier"]) {
                bid = AIPBundleIDFromObject([parent propertyForKey:key]);
                if (bid) return bid;
            }
        }
        bid = AIPBundleIDForAppName([parent respondsToSelector:@selector(name)] ? [parent name] : nil);
        if (bid) return bid;
    }
    return AIPBundleIDForAppName([controller title]);
}

#pragma mark - Helper xử lý 2 nút

@implementation AIPSettingsHelper

+ (instancetype)sharedHelper {
    static AIPSettingsHelper *helper = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        helper = [[AIPSettingsHelper alloc] init];
    });
    return helper;
}

- (NSString *)bundleIDFromSpecifier:(id)specifier {
    NSString *bid = nil;
    if ([specifier respondsToSelector:@selector(propertyForKey:)]) {
        bid = AIPBundleIDFromObject([specifier propertyForKey:@"AIPBundleID"]);
    }
    if (!bid && gDetailController) bid = AIPResolveDetailBundleID(gDetailController);
    return bid;
}

- (void)showMessage:(NSString *)message {
    UIViewController *top = AIPSettingsTopViewController();
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AppInfoPress" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

- (void)reloadDetailPage {
    if (gDetailController && [gDetailController respondsToSelector:@selector(reloadSpecifiers)]) {
        [gDetailController reloadSpecifiers];
    }
}

- (void)aipClearCacheTapped:(id)specifier {
    NSString *bundleID = [self bundleIDFromSpecifier:specifier];
    if (!bundleID) {
        AIPLog(@"Nut Xoa cache: khong xac dinh duoc app, bo qua");
        [self showMessage:@"Chưa xác định được app của trang này. Bật log rồi gửi file AppInfoPress.log cho Muse nhé."];
        return;
    }
    NSString *appName = AIPAppNameForBundleID(bundleID, bundleID.lastPathComponent);
    UIViewController *top = AIPSettingsTopViewController();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xoá bộ nhớ đệm"
        message:[NSString stringWithFormat:@"Xoá bộ nhớ đệm (cache) của %@? Tài liệu và đăng nhập vẫn giữ nguyên.", appName]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xoá" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            long long freed = AIPClearCacheForBundleID(bundleID);
            dispatch_async(dispatch_get_main_queue(), ^{
                AIPLog(@"Cai dat: xoa cache %@ -> %lld byte", bundleID, freed);
                [self reloadDetailPage];
                if (freed < 0) [self showMessage:@"Không tìm thấy thư mục dữ liệu của app."];
                else [self showMessage:[NSString stringWithFormat:@"Đã xoá bộ nhớ đệm của %@ — giải phóng khoảng %@.", appName, AIPByteString((unsigned long long)freed)]];
            });
        });
    }]];
    [top presentViewController:alert animated:YES completion:nil];
}

- (void)aipResetTapped:(id)specifier {
    NSString *bundleID = [self bundleIDFromSpecifier:specifier];
    if (!bundleID) {
        AIPLog(@"Nut Dat lai: khong xac dinh duoc app, bo qua");
        [self showMessage:@"Chưa xác định được app của trang này. Bật log rồi gửi file AppInfoPress.log cho Muse nhé."];
        return;
    }
    NSString *appName = AIPAppNameForBundleID(bundleID, bundleID.lastPathComponent);
    UIViewController *top = AIPSettingsTopViewController();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đặt lại app"
        message:[NSString stringWithFormat:@"Đặt lại %@ về như mới cài? Toàn bộ dữ liệu trong app sẽ bị xoá sạch. App vẫn còn trên máy.", appName]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đặt lại" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            long long freed = AIPResetDataForBundleID(bundleID);
            dispatch_async(dispatch_get_main_queue(), ^{
                AIPLog(@"Cai dat: dat lai %@ -> %lld byte", bundleID, freed);
                [self reloadDetailPage];
                if (freed < 0) [self showMessage:@"Không tìm thấy thư mục dữ liệu của app."];
                else [self showMessage:[NSString stringWithFormat:@"Đã đặt lại %@ về trạng thái như mới cài.", appName]];
            });
        });
    }]];
    [top presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Nhận diện trang + tạo nút

static id AIPMakeButtonSpecifier(NSString *title, SEL action, int cellType, NSString *kind, NSString *bundleID) {
    Class specClass = NSClassFromString(@"PSSpecifier");
    if (!specClass) return nil;
    // Ép kiểu về PSSpecifier * (không để id): tránh lỗi "multiple methods named
    // 'setProperty:forKey:'" do NSStream cũng có method trùng tên khác chữ ký.
    PSSpecifier *spec = (PSSpecifier *)((id (*)(id, SEL, id, id, SEL, SEL, Class, int, Class))objc_msgSend)(specClass,
        @selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:),
        title, [AIPSettingsHelper sharedHelper], NULL, NULL, Nil, cellType, Nil);
    if (!spec) return nil;
    if ([spec respondsToSelector:@selector(setButtonAction:)]) {
        ((void (*)(id, SEL, SEL))objc_msgSend)(spec, @selector(setButtonAction:), action);
    }
    if ([spec respondsToSelector:@selector(setProperty:forKey:)]) {
        [spec setProperty:kind forKey:@"AIPKind"];
        if (bundleID) [spec setProperty:bundleID forKey:@"AIPBundleID"];
    }
    return spec;
}

// Trang chi tiết dung lượng của 1 app. Bản 1.0.1 nới lỏng: cặp Gỡ bỏ + Xoá là đủ
// (bản 1.0.0 đòi thêm dòng dung lượng — trên iOS 16 dòng đó không phải specifier).
static BOOL AIPIsStorageDetailPage(NSArray *specifiers, NSString *controllerClassName, int *deleteCellTypeOut) {
    BOOL hasOffload = NO;
    BOOL hasSize = NO;
    BOOL hasDelete = NO;
    for (id spec in specifiers) {
        NSString *name = AIPLower([spec respondsToSelector:@selector(name)] ? [spec name] : nil);
        NSString *identifier = AIPLower([spec respondsToSelector:@selector(identifier)] ? [spec identifier] : nil);
        if (AIPTextMatches(name, @[@"offload"]) || AIPTextMatches(identifier, @[@"offload"]) || [name containsString:@"gỡ bỏ ứng dụng"]) hasOffload = YES;
        if (AIPTextMatches(name, @[@"app size", @"documents & data"]) || [name containsString:@"kích thước ứng dụng"]) hasSize = YES;
        if (AIPTextMatches(name, @[@"delete app"]) || AIPTextMatches(identifier, @[@"delete"]) || [name containsString:@"xoá ứng dụng"]) {
            hasDelete = YES;
            if (deleteCellTypeOut && [spec respondsToSelector:@selector(cellType)]) {
                *deleteCellTypeOut = ((int (*)(id, SEL))objc_msgSend)(spec, @selector(cellType));
            }
        }
    }
    BOOL classLooksDetail = [controllerClassName containsString:@"Storage"] &&
        ([controllerClassName containsString:@"Detail"] || [controllerClassName containsString:@"App"]);
    return (hasOffload && hasDelete) || (hasOffload && hasSize) || (hasSize && hasDelete) || (hasDelete && classLooksDetail);
}

static BOOL AIPAlreadyInjected(NSArray *specifiers) {
    for (id spec in specifiers) {
        if ([spec respondsToSelector:@selector(propertyForKey:)]) {
            id kind = [spec propertyForKey:@"AIPKind"];
            if (kind) return YES;
        }
    }
    return NO;
}

// Ghi log 1 lần cho mỗi class đáng ngờ: tên class + toàn bộ specifier của nó.
// Đây là bằng chứng để vòng sửa sau (nếu còn) đánh trúng ngay lần đầu.
static void AIPDumpSpecifiersOnce(id controller, NSArray *specifiers) {
    NSString *className = NSStringFromClass([controller class]) ?: @"";
    BOOL interesting = [className containsString:@"Storage"];
    if (!interesting) {
        for (id spec in specifiers) {
            NSString *name = AIPLower([spec respondsToSelector:@selector(name)] ? [spec name] : nil);
            if ([name containsString:@"offload"] || [name containsString:@"delete"] ||
                [name containsString:@"xoá"] || [name containsString:@"gỡ bỏ"]) { interesting = YES; break; }
        }
    }
    if (!interesting) return;
    static NSMutableSet<NSString *> *dumped = nil;
    if (!dumped) dumped = [NSMutableSet set];
    @synchronized (dumped) {
        if ([dumped containsObject:className]) return;
        [dumped addObject:className];
    }
    NSMutableString *dump = [NSMutableString stringWithFormat:@"Trang %@ (%d specifiers):", className, (int)specifiers.count];
    for (id spec in specifiers) {
        NSString *name = [spec respondsToSelector:@selector(name)] ? [spec name] : nil;
        NSString *identifier = [spec respondsToSelector:@selector(identifier)] ? [spec identifier] : nil;
        int cellType = -1;
        if ([spec respondsToSelector:@selector(cellType)]) cellType = ((int (*)(id, SEL))objc_msgSend)(spec, @selector(cellType));
        [dump appendFormat:@"\n  - name='%@' id='%@' cell=%d", name ?: @"", identifier ?: @"", cellType];
    }
    AIPLog(@"%@", dump);
}

#pragma mark - Lấy specifiers gốc (không qua hook)

static IMP AIPOriginalForClass(Class cls) {
    while (cls) {
        NSValue *value = gSpecOriginals[NSStringFromClass(cls)];
        if (value) return (IMP)[value pointerValue];
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static BOOL AIPClassHasOwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

static NSArray *AIPRawSpecifiers(id controller) {
    if (!controller) return nil;
    Class cls = [controller class];
    // Class tự viết lại -specifiers nhưng chưa kịp hook thì gọi thẳng như thường
    // (đó chính là bản gốc của nó), tránh gọi nhầm bản gốc của lớp cha.
    if (AIPClassHasOwnMethod(cls, @selector(specifiers)) && !gSpecOriginals[NSStringFromClass(cls)]) {
        if ([controller respondsToSelector:@selector(specifiers)]) return [controller specifiers];
        return nil;
    }
    IMP orig = AIPOriginalForClass(cls);
    if (orig) return ((NSArray *(*)(id, SEL))orig)(controller, @selector(specifiers));
    if ([controller respondsToSelector:@selector(specifiers)]) return [controller specifiers];
    return nil;
}

#pragma mark - Tự nhảy vào app trong danh sách dung lượng

static id AIPMatchSpecifier(NSArray *specifiers, NSString *bundleID, NSString *appName) {
    for (id spec in specifiers) {
        if ([AIPBundleIDFromObject([spec respondsToSelector:@selector(identifier)] ? [spec identifier] : nil) isEqualToString:bundleID]) return spec;
        if ([spec respondsToSelector:@selector(userInfo)]) {
            NSDictionary *info = ((NSDictionary *(*)(id, SEL))objc_msgSend)(spec, @selector(userInfo));
            if ([info isKindOfClass:[NSDictionary class]]) {
                for (id key in info) {
                    if ([AIPBundleIDFromObject(info[key]) isEqualToString:bundleID]) return spec;
                }
            }
        }
        if ([spec respondsToSelector:@selector(propertyForKey:)]) {
            for (NSString *key in @[@"application", @"app", @"bundleIdentifier", @"bundleID", @"applicationIdentifier"]) {
                if ([AIPBundleIDFromObject([spec propertyForKey:key]) isEqualToString:bundleID]) return spec;
            }
        }
        if (appName.length > 0 && [spec respondsToSelector:@selector(name)] && [[spec name] isEqualToString:appName]) return spec;
    }
    return nil;
}

// Trả YES chỉ khi đã chọn được dòng của app. Thất bại có thể phát hiện được thì
// giữ nguyên yêu cầu chờ để bộ theo dõi thử lại ở nhịp sau.
static BOOL AIPTryJumpWithController(id controller, NSArray *specifiers, NSString *pendingApp) {
    if (!controller || !specifiers || pendingApp.length == 0) return NO;
    NSString *appName = AIPAppNameForBundleID(pendingApp, @"");
    id matched = AIPMatchSpecifier(specifiers, pendingApp, appName);
    if (!matched) return NO;
    if (![controller respondsToSelector:@selector(indexPathForSpecifier:)] ||
        ![controller respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
    NSIndexPath *indexPath = ((NSIndexPath *(*)(id, SEL, id))objc_msgSend)(controller, @selector(indexPathForSpecifier:), matched);
    UITableView *table = nil;
    if ([controller respondsToSelector:@selector(table)]) table = ((UITableView *(*)(id, SEL))objc_msgSend)(controller, @selector(table));
    if (!table && [controller respondsToSelector:@selector(tableView)]) table = ((UITableView *(*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
    if (!indexPath || !table) {
        AIPLog(@"Dung luong: thay %@ trong danh sach nhung chua lay duoc indexPath/table, thu lai sau", pendingApp);
        return NO;
    }
    AIPSetPrefValue(@"pendingStorageApp", nil);
    AIPLog(@"Dung luong: tu nhay vao trang cua %@", pendingApp);
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(controller, @selector(tableView:didSelectRowAtIndexPath:), table, indexPath);
    } @catch (NSException *exception) {
        AIPLog(@"Dung luong: nhay that bai: %@", exception.reason);
    }
    return YES;
}

static void AIPCollectControllers(UIViewController *vc, NSMutableArray *out) {
    if (!vc) return;
    [out addObject:vc];
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in [(UINavigationController *)vc viewControllers]) AIPCollectControllers(child, out);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in [(UITabBarController *)vc viewControllers]) AIPCollectControllers(child, out);
    }
    for (UIViewController *child in vc.childViewControllers) AIPCollectControllers(child, out);
    AIPCollectControllers(vc.presentedViewController, out);
}

// Tìm controller của trang danh sách dung lượng trong cây view controller hiện tại
// (phòng khi trang đã mở sẵn từ trước và hook -specifiers không chạy lại).
static id AIPFindStorageControllerInHierarchy(void) {
    NSMutableArray *all = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            AIPCollectControllers(window.rootViewController, all);
        }
    }
    for (UIViewController *vc in all) {
        NSString *name = NSStringFromClass([vc class]) ?: @"";
        if (![name containsString:@"Storage"]) continue;
        if (![vc respondsToSelector:@selector(specifiers)]) continue;
        NSArray *specs = AIPRawSpecifiers(vc);
        int cellType = 3;
        if (specs && !AIPIsStorageDetailPage(specs, name, &cellType)) return vc;
    }
    return nil;
}

static void AIPAttemptPendingJump(void) {
    @try {
        NSDictionary *prefs = AIPLoadPrefs();
        NSString *pendingApp = prefs[@"pendingStorageApp"];
        NSNumber *pendingAt = prefs[@"pendingStorageAt"];
        if (![pendingApp isKindOfClass:[NSString class]] || pendingApp.length == 0) {
            gJumpAttemptCount = 0;
            return;
        }
        if ([pendingAt isKindOfClass:[NSNumber class]] && [[NSDate date] timeIntervalSince1970] - [pendingAt doubleValue] > 30) {
            AIPSetPrefValue(@"pendingStorageApp", nil);
            AIPLog(@"Dung luong: yeu cau nhay vao %@ da qua 30 giay, huy", pendingApp);
            return;
        }
        if (!AIPPrefEnabled(prefs, @"enabled", YES)) return;
        gJumpAttemptCount++;
        BOOL verbose = (gJumpAttemptCount <= 3 || gJumpAttemptCount % 5 == 0);
        id controller = gLastStorageListController;
        if (!controller) controller = AIPFindStorageControllerInHierarchy();
        if (!controller) {
            if (verbose) AIPLog(@"Dung luong: lan thu %d — chua thay trang danh sach dung luong", gJumpAttemptCount);
            return;
        }
        NSArray *specs = AIPRawSpecifiers(controller);
        if (!specs) {
            if (verbose) AIPLog(@"Dung luong: lan thu %d — trang danh sach chua co specifiers", gJumpAttemptCount);
            return;
        }
        NSString *className = NSStringFromClass([controller class]) ?: @"";
        int cellType = 3;
        if (AIPIsStorageDetailPage(specs, className, &cellType)) {
            NSString *bid = AIPResolveDetailBundleID(controller);
            if ([bid isEqualToString:pendingApp]) {
                AIPSetPrefValue(@"pendingStorageApp", nil);
                AIPLog(@"Dung luong: dang o dung trang cua %@ — xong", pendingApp);
            }
            return;
        }
        if (!AIPTryJumpWithController(controller, specs, pendingApp) && verbose) {
            AIPLog(@"Dung luong: lan thu %d — chua thay %@ trong danh sach", gJumpAttemptCount, pendingApp);
        }
    } @catch (NSException *exception) {
        AIPLog(@"Thu nhay trang dung luong loi: %@", exception.reason);
    }
}

// Bộ theo dõi nền: cứ 2 giây kiểm tra một lần xem có yêu cầu nhảy đang chờ không.
// Danh sách dung lượng nạp app dần, thử một lần như bản 1.0.0 rất dễ hụt.
static void AIPPendingWatcherTick(void) {
    AIPAttemptPendingJump();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AIPPendingWatcherTick();
    });
}

#pragma mark - Hook -specifiers (dùng chung cho mọi class đã hook)

static void AIPScanAndHookStorageClasses(void);

static NSArray *AIPProcessSpecifiers(id controller, NSArray *specifiers) {
    @try {
        if (!specifiers) return specifiers;
        AIPScanAndHookStorageClasses();
        NSDictionary *prefs = AIPLoadPrefs();
        if (!AIPPrefEnabled(prefs, @"enabled", YES)) return specifiers;
        NSString *className = NSStringFromClass([controller class]) ?: @"";
        AIPDumpSpecifiersOnce(controller, specifiers);
        int cellType = 3; // PSButtonCell
        if (AIPIsStorageDetailPage(specifiers, className, &cellType)) {
            gDetailController = controller;
            if (AIPPrefEnabled(prefs, @"settingsButtons", YES) && !AIPAlreadyInjected(specifiers)) {
                NSString *bundleID = AIPResolveDetailBundleID(controller);
                AIPLog(@"Trang dung luong cua app: %@ — them 2 nut AppInfoPress", bundleID ?: @"(chua ro)");
                NSMutableArray *extended = [specifiers mutableCopy];
                id reset = AIPMakeButtonSpecifier(@"Reset App", @selector(aipResetTapped:), cellType, @"reset", bundleID);
                id clear = AIPMakeButtonSpecifier(@"Clear App's Cache", @selector(aipClearCacheTapped:), cellType, @"clear", bundleID);
                if (reset) [extended addObject:reset];
                if (clear) [extended addObject:clear];
                if (reset || clear) return [extended copy];
            }
            return specifiers;
        }
        if ([className containsString:@"Storage"]) {
            gLastStorageListController = controller;
            NSString *pendingApp = prefs[@"pendingStorageApp"];
            if ([pendingApp isKindOfClass:[NSString class]] && pendingApp.length > 0) {
                AIPTryJumpWithController(controller, specifiers, pendingApp);
            }
        }
    } @catch (NSException *exception) {
        AIPLog(@"Xu ly specifiers loi: %@", exception.reason);
    }
    return specifiers;
}

static NSArray *AIPSpecifiersHookGeneric(id self, SEL _cmd) {
    IMP orig = AIPOriginalForClass([self class]);
    if (!orig) return nil;
    NSArray *specifiers = ((NSArray *(*)(id, SEL))orig)(self, _cmd);
    return AIPProcessSpecifiers(self, specifiers);
}

#pragma mark - Hook viewWillAppear (bắt các trang Storage hiện lên)

static void (*AIPOriginalViewWillAppear)(id, SEL, BOOL) = NULL;

static void AIPViewWillAppearHook(id self, SEL _cmd, BOOL animated) {
    if (AIPOriginalViewWillAppear) AIPOriginalViewWillAppear(self, _cmd, animated);
    @try {
        NSString *className = NSStringFromClass([self class]) ?: @"";
        if ([className containsString:@"Storage"]) {
            AIPScanAndHookStorageClasses();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                AIPAttemptPendingJump();
            });
        }
    } @catch (NSException *exception) {}
}

#pragma mark - Quét + cài hook

static void AIPHookSpecifiersForClass(Class cls) {
    if (!gSpecOriginals) gSpecOriginals = [NSMutableDictionary dictionary];
    NSString *key = NSStringFromClass(cls);
    if (gSpecOriginals[key]) return;
    IMP orig = NULL;
    MSHookMessageEx(cls, @selector(specifiers), (IMP)AIPSpecifiersHookGeneric, &orig);
    if (orig) {
        gSpecOriginals[key] = [NSValue valueWithPointer:(void *)orig];
        AIPLog(@"Cai dat: da hook -specifiers cua %@", key);
    } else {
        AIPLog(@"Cai dat: hook -specifiers cua %@ THAT BAI", key);
    }
}

static void AIPLogStorageClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name containsString:@"Storage"]) {
            NSString *superName = NSStringFromClass(class_getSuperclass(classes[i])) ?: @"?";
            [names addObject:[NSString stringWithFormat:@"%@ (cha: %@)", name, superName]];
        }
    }
    free(classes);
    [names sortUsingSelector:@selector(compare:)];
    NSString *dump = [names componentsJoinedByString:@", "];
    static NSString *lastDump = nil;
    if (![dump isEqualToString:lastDump]) {
        lastDump = [dump copy];
        AIPLog(@"Cac class chua 'Storage' trong Cai dat: %@", dump);
    }
}

// Các class Storage thường chỉ nạp khi người dùng mò vào Cài đặt chung, nên phải
// quét lại nhiều lần (có chống spam 5 giây) mới bắt được hết.
static void AIPScanAndHookStorageClasses(void) {
    static NSDate *lastScan = nil;
    NSDate *now = [NSDate date];
    if (lastScan && [now timeIntervalSinceDate:lastScan] < 5.0) return;
    lastScan = now;
    AIPLogStorageClasses();
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (![name containsString:@"Storage"]) continue;
        if (AIPClassHasOwnMethod(classes[i], @selector(specifiers))) {
            AIPHookSpecifiersForClass(classes[i]);
        }
    }
    free(classes);
}

static void AIPInstallHook(int attempt) {
    Class listClass = NSClassFromString(@"PSListController");
    if (!listClass) {
        if (attempt < 5) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                AIPInstallHook(attempt + 1);
            });
        } else {
            AIPLog(@"Cai dat: KHONG thay PSListController sau 5 lan thu");
        }
        return;
    }
    AIPHookSpecifiersForClass(listClass);
    if (!AIPOriginalViewWillAppear) {
        MSHookMessageEx(listClass, @selector(viewWillAppear:), (IMP)AIPViewWillAppearHook, (IMP *)&AIPOriginalViewWillAppear);
    }
    AIPScanAndHookStorageClasses();
    AIPLog(@"Cai dat: da cai hook xong (PSListController + quet class Storage)");
}

%ctor {
    NSDictionary *prefs = AIPLoadPrefs();
    AIPLog(@"AppInfoPress (Cai dat) da nap — enabled=%@, settingsButtons=%@", AIPPrefEnabled(prefs, @"enabled", YES) ? @"YES" : @"NO", AIPPrefEnabled(prefs, @"settingsButtons", YES) ? @"YES" : @"NO");
    AIPInstallHook(0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AIPPendingWatcherTick();
    });
}
