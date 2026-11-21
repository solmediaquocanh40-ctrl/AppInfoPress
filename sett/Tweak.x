// AppInfoPress (phần Cài đặt) — com.anhdang.appinfopress
// Hai việc trong app Cài đặt:
//   1) Thêm 2 nút "Đặt lại app" + "Xoá bộ nhớ đệm của app" vào trang dung lượng
//      của từng app (Cài đặt chung -> Dung lượng iPhone -> app), kiểu CacheClearer.
//   2) Khi phía SpringBoard xin mở trang dung lượng của 1 app cụ thể, tự nhảy tiếp
//      từ danh sách dung lượng vào đúng app đó.
// Toàn bộ hook bằng MSHookMessageEx lên PSListController + dò specifier, có log
// chẩn đoán lớp Storage để tinh chỉnh theo máy thật. Lỗi ở đâu cũng bỏ qua êm.

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

// Tìm bundle id của app mà trang chi tiết đang hiển thị, từ specifier cha.
static NSString *AIPResolveDetailBundleID(id controller) {
    id parent = nil;
    if ([controller respondsToSelector:@selector(specifier)]) {
        parent = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(specifier));
    }
    if (!parent) return nil;
    NSString *bid = AIPBundleIDFromObject([parent identifier]);
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
    bid = AIPBundleIDForAppName([parent name]);
    if (bid) return bid;
    return nil;
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

#pragma mark - Hook PSListController -specifiers

static NSArray *(*AIPOriginalSpecifiers)(id self, SEL _cmd) = NULL;

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

static BOOL AIPIsStorageDetailPage(NSArray *specifiers, int *deleteCellTypeOut) {
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
    return (hasOffload && hasSize) || (hasSize && hasDelete);
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

static void AIPTryPendingStorageJump(id controller, NSArray *specifiers) {
    NSDictionary *prefs = AIPLoadPrefs();
    NSString *pendingApp = prefs[@"pendingStorageApp"];
    NSNumber *pendingAt = prefs[@"pendingStorageAt"];
    if (![pendingApp isKindOfClass:[NSString class]] || pendingApp.length == 0) return;
    if ([pendingAt isKindOfClass:[NSNumber class]] && [[NSDate date] timeIntervalSince1970] - [pendingAt doubleValue] > 30) {
        AIPSetPrefValue(@"pendingStorageApp", nil);
        return;
    }
    NSString *controllerClass = NSStringFromClass([controller class]) ?: @"";
    if (![controllerClass containsString:@"Storage"]) return;
    NSString *appName = AIPAppNameForBundleID(pendingApp, @"");
    id matched = nil;
    for (id spec in specifiers) {
        if ([AIPBundleIDFromObject([spec respondsToSelector:@selector(identifier)] ? [spec identifier] : nil) isEqualToString:pendingApp]) { matched = spec; break; }
        if ([spec respondsToSelector:@selector(userInfo)]) {
            NSDictionary *info = ((NSDictionary *(*)(id, SEL))objc_msgSend)(spec, @selector(userInfo));
            if ([info isKindOfClass:[NSDictionary class]]) {
                for (id key in info) {
                    if ([AIPBundleIDFromObject(info[key]) isEqualToString:pendingApp]) { matched = spec; break; }
                }
            }
            if (matched) break;
        }
        if (appName.length > 0 && [[spec name] isEqualToString:appName]) { matched = spec; break; }
    }
    if (!matched) return;
    AIPSetPrefValue(@"pendingStorageApp", nil);
    AIPLog(@"Dung luong: tim thay %@ trong danh sach, tu nhay vao", pendingApp);
    id target = controller;
    id targetSpec = matched;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            NSIndexPath *indexPath = [target indexPathForSpecifier:targetSpec];
            UITableView *table = [target table];
            if (indexPath && table) {
                [target tableView:table didSelectRowAtIndexPath:indexPath];
                AIPLog(@"Dung luong: da nhay vao trang cua app");
            } else {
                AIPLog(@"Dung luong: khong lay duoc indexPath/table de nhay");
            }
        } @catch (NSException *exception) {
            AIPLog(@"Dung luong: nhay that bai: %@", exception.reason);
        }
    });
}

static NSArray *AIPSpecifiersHook(id self, SEL _cmd) {
    if (!AIPOriginalSpecifiers) return nil;
    NSArray *specifiers = AIPOriginalSpecifiers(self, _cmd);
    @try {
        if (!specifiers) return specifiers;
        NSDictionary *prefs = AIPLoadPrefs();
        if (!AIPPrefEnabled(prefs, @"enabled", YES)) return specifiers;

        int cellType = 3; // PSButtonCell
        if (AIPIsStorageDetailPage(specifiers, &cellType)) {
            gDetailController = self;
            if (AIPPrefEnabled(prefs, @"settingsButtons", YES) && !AIPAlreadyInjected(specifiers)) {
                NSString *bundleID = AIPResolveDetailBundleID(self);
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
        AIPTryPendingStorageJump(self, specifiers);
    } @catch (NSException *exception) {
        AIPLog(@"Hook specifiers loi: %@", exception.reason);
    }
    return specifiers;
}

#pragma mark - Khởi động

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
    MSHookMessageEx(listClass, @selector(specifiers), (IMP)AIPSpecifiersHook, (IMP *)&AIPOriginalSpecifiers);
    AIPLog(@"Cai dat: da hook PSListController -specifiers");
}

static void AIPLogStorageClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name containsString:@"Storage"]) [names addObject:name];
    }
    free(classes);
    AIPLog(@"Cac class chua 'Storage' trong Cai dat: %@", [names componentsJoinedByString:@", "]);
}

%ctor {
    NSDictionary *prefs = AIPLoadPrefs();
    AIPLog(@"AppInfoPress (Cai dat) da nap — enabled=%@, settingsButtons=%@", AIPPrefEnabled(prefs, @"enabled", YES) ? @"YES" : @"NO", AIPPrefEnabled(prefs, @"settingsButtons", YES) ? @"YES" : @"NO");
    AIPLogStorageClasses();
    AIPInstallHook(0);
}
