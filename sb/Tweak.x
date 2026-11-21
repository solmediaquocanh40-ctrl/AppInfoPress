// AppInfoPress (phần SpringBoard) — com.anhdang.appinfopress
// Ấn giữ icon ngoài màn hình chính: thêm vào menu các mục
//   Thông tin ứng dụng / Dung lượng & bộ nhớ đệm / Xoá bộ nhớ đệm / Đặt lại app
// như trang "Thông tin ứng dụng" của Android. Mọi truy cập class hệ thống đều dò
// bằng respondsToSelector/objc_msgSend, không có thì bỏ qua êm, không văng máy.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "AIPShared.h"

@interface SBIconView : UIView
@property (nonatomic, readonly, strong) id icon;
@end

static NSDictionary *gPrefs = nil;

static BOOL AIPMasterEnabled(void) {
    return AIPPrefEnabled(gPrefs, @"enabled", YES);
}

#pragma mark - Dò bundle id / tên app từ icon

static NSString *AIPIconBundleID(id icon, NSString **nameOut) {
    if (!icon) return nil;
    Class appIconClass = NSClassFromString(@"SBApplicationIcon");
    if (appIconClass && ![icon isKindOfClass:appIconClass]) return nil;
    NSString *bid = nil;
    NSString *name = nil;
    static BOOL loggedPath = NO;
    if ([icon respondsToSelector:@selector(applicationBundleID)]) {
        bid = ((NSString *(*)(id, SEL))objc_msgSend)(icon, @selector(applicationBundleID));
        if (bid.length > 0 && !loggedPath) { loggedPath = YES; AIPLog(@"Icon: lay bundle id qua applicationBundleID"); }
    }
    if (bid.length == 0 && [icon respondsToSelector:@selector(application)]) {
        id app = ((id (*)(id, SEL))objc_msgSend)(icon, @selector(application));
        if ([app respondsToSelector:@selector(bundleIdentifier)]) {
            bid = ((NSString *(*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
            if (bid.length > 0 && !loggedPath) { loggedPath = YES; AIPLog(@"Icon: lay bundle id qua application.bundleIdentifier"); }
        }
        if ([app respondsToSelector:@selector(displayName)]) {
            name = ((NSString *(*)(id, SEL))objc_msgSend)(app, @selector(displayName));
        }
    }
    if (bid.length == 0 && [icon respondsToSelector:@selector(bundleIdentifier)]) {
        bid = ((NSString *(*)(id, SEL))objc_msgSend)(icon, @selector(bundleIdentifier));
    }
    if (nameOut) *nameOut = name;
    return bid.length > 0 ? bid : nil;
}

#pragma mark - Trình bày hộp thoại trên SpringBoard

static UIViewController *AIPTopViewController(void) {
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
    return top;
}

static void AIPShowAlert(NSString *title, NSString *message) {
    UIViewController *top = AIPTopViewController();
    if (!top) {
        AIPLog(@"Khong co view controller de hien hop thoai: %@ — %@", title, message);
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Mở các trang trong Cài đặt

static void AIPOpenURL(NSString *urlString, void (^fallback)(void)) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (fallback) fallback();
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        AIPLog(@"Mo URL %@: %@", urlString, success ? @"OK" : @"THAT BAI");
        if (!success && fallback) fallback();
    }];
}

static void AIPOpenAppStorage(NSString *bundleID);

static void AIPOpenAppInfo(NSString *bundleID) {
    // Theo yêu cầu của Quoc (2026-11-21): "Thông tin ứng dụng" phải mở thẳng
    // trang của app trong Cài đặt chung -> Dung lượng iPhone (trang có Gỡ bỏ
    // ứng dụng / Xoá ứng dụng và 2 nút Reset App / Clear App's Cache bên dưới),
    // giống trang App info của Android — dùng chung đường nhảy với mục
    // "Dung lượng & bộ nhớ đệm", không mở trang cài đặt riêng của app nữa.
    AIPOpenAppStorage(bundleID);
}

static void AIPOpenAppStorage(NSString *bundleID) {
    // Nhắn cho phía Cài đặt biết app nào đang được xin mở trang dung lượng,
    // để nó tự nhảy tiếp vào đúng app khi danh sách dung lượng hiện ra.
    AIPSetPrefValue(@"pendingStorageApp", bundleID);
    AIPSetPrefValue(@"pendingStorageAt", @([[NSDate date] timeIntervalSince1970]));
    AIPOpenURL(@"App-prefs:root=General&path=STORAGE_MGMT", ^{
        AIPOpenURL(@"App-prefs:root=General", ^{
            AIPOpenURL(@"App-prefs:", nil);
        });
    });
}

#pragma mark - Xoá cache / đặt lại app ngay tại màn hình chính

static void AIPKillAppIfPossible(NSString *bundleID) {
    Class controllerClass = NSClassFromString(@"SBApplicationController");
    if (!controllerClass) return;
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, @selector(sharedInstance));
    if (![controller respondsToSelector:@selector(applicationWithBundleIdentifier:)]) return;
    id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, @selector(applicationWithBundleIdentifier:), bundleID);
    if (!app) return;
    SEL killSel = @selector(killForReason:andReport:withDescription:);
    if ([app respondsToSelector:killSel]) {
        ((void (*)(id, SEL, NSInteger, BOOL, id))objc_msgSend)(app, killSel, (NSInteger)1, NO, nil);
        AIPLog(@"Da dung app %@ truoc khi dat lai", bundleID);
    } else {
        AIPLog(@"Khong thay cach dung app %@ (van xoa du lieu, app dang mo co the ghi de lai)", bundleID);
    }
}

static void AIPRunClearCache(NSString *bundleID, NSString *appName) {
    // Chờ menu ấn giữ đóng hẳn rồi mới hiện hộp thoại (tránh lỗi đang-trình-bày).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!AIPDataContainerURLForBundleID(bundleID)) {
            AIPShowAlert(@"Không tìm thấy dữ liệu", [NSString stringWithFormat:@"Không tìm thấy thư mục dữ liệu của %@.", appName]);
            return;
        }
        UIViewController *top = AIPTopViewController();
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xoá bộ nhớ đệm"
            message:[NSString stringWithFormat:@"Xoá bộ nhớ đệm (cache) của %@? Tài liệu và đăng nhập vẫn giữ nguyên.", appName]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Xoá" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                long long freed = AIPClearCacheForBundleID(bundleID);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (freed < 0) {
                        AIPShowAlert(@"Chưa xoá được", @"Không tìm thấy thư mục dữ liệu của app.");
                    } else {
                        AIPLog(@"Da xoa cache cua %@: giai phong ~%lld byte", bundleID, freed);
                        AIPShowAlert(@"Đã xoá bộ nhớ đệm", [NSString stringWithFormat:@"%@ — giải phóng khoảng %@.", appName, AIPByteString((unsigned long long)freed)]);
                    }
                });
            });
        }]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

static void AIPRunResetApp(NSString *bundleID, NSString *appName) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!AIPDataContainerURLForBundleID(bundleID)) {
            AIPShowAlert(@"Không tìm thấy dữ liệu", [NSString stringWithFormat:@"Không tìm thấy thư mục dữ liệu của %@.", appName]);
            return;
        }
        UIViewController *top = AIPTopViewController();
        if (!top) return;
        UIAlertController *first = [UIAlertController alertControllerWithTitle:@"Đặt lại app"
            message:[NSString stringWithFormat:@"Đặt lại %@ về như mới cài? Toàn bộ dữ liệu trong app (tài khoản, tài liệu, cài đặt riêng) sẽ bị xoá sạch. App vẫn còn trên máy.", appName]
            preferredStyle:UIAlertControllerStyleAlert];
        [first addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
        [first addAction:[UIAlertAction actionWithTitle:@"Tiếp tục" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            UIAlertController *second = [UIAlertController alertControllerWithTitle:@"Chắc chắn đặt lại?"
                message:[NSString stringWithFormat:@"Xoá sạch dữ liệu của %@ — không khôi phục được.", appName]
                preferredStyle:UIAlertControllerStyleAlert];
            [second addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
            [second addAction:[UIAlertAction actionWithTitle:@"Đặt lại" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action2) {
                AIPKillAppIfPossible(bundleID);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    long long freed = AIPResetDataForBundleID(bundleID);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (freed < 0) {
                            AIPShowAlert(@"Chưa đặt lại được", @"Không tìm thấy thư mục dữ liệu của app.");
                        } else {
                            AIPLog(@"Da dat lai %@: giai phong ~%lld byte", bundleID, freed);
                            AIPShowAlert(@"Đã đặt lại app", [NSString stringWithFormat:@"%@ đã về trạng thái như mới cài.", appName]);
                        }
                    });
                });
            }]];
            UIViewController *top2 = AIPTopViewController();
            [top2 presentViewController:second animated:YES completion:nil];
        }]];
        [top presentViewController:first animated:YES completion:nil];
    });
}

#pragma mark - Dựng các mục menu

static NSArray<UIAction *> *AIPMenuActions(NSString *bundleID, NSString *appName) {
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    if (AIPPrefEnabled(gPrefs, @"showInfo", YES)) {
        UIAction *info = [UIAction actionWithTitle:@"Thông tin ứng dụng" image:[UIImage systemImageNamed:@"info.circle"] identifier:@"appinfopress.info" handler:^(__kindof UIAction *action) {
            AIPOpenAppInfo(bundleID);
        }];
        [actions addObject:info];
    }
    if (AIPPrefEnabled(gPrefs, @"showStorage", YES)) {
        UIAction *storage = [UIAction actionWithTitle:@"Dung lượng & bộ nhớ đệm" image:[UIImage systemImageNamed:@"externaldrive"] identifier:@"appinfopress.storage" handler:^(__kindof UIAction *action) {
            AIPOpenAppStorage(bundleID);
        }];
        [actions addObject:storage];
    }
    if (AIPPrefEnabled(gPrefs, @"showClear", YES)) {
        UIAction *clear = [UIAction actionWithTitle:@"Xoá bộ nhớ đệm" image:[UIImage systemImageNamed:@"trash"] identifier:@"appinfopress.clear" handler:^(__kindof UIAction *action) {
            AIPRunClearCache(bundleID, appName);
        }];
        [actions addObject:clear];
    }
    if (AIPPrefEnabled(gPrefs, @"showReset", YES)) {
        UIAction *reset = [UIAction actionWithTitle:@"Đặt lại app" image:[UIImage systemImageNamed:@"exclamationmark.triangle"] identifier:@"appinfopress.reset" handler:^(__kindof UIAction *action) {
            AIPRunResetApp(bundleID, appName);
        }];
        reset.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:reset];
    }
    return [actions copy];
}

#pragma mark - Hook menu ấn giữ của icon

%hook SBIconView

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIContextMenuConfiguration *config = %orig;
    if (!config || !AIPMasterEnabled()) return config;
    NSString *name = nil;
    NSString *bundleID = AIPIconBundleID(self.icon, &name);
    if (!bundleID) return config;
    NSString *appName = name.length > 0 ? name : AIPAppNameForBundleID(bundleID, bundleID.lastPathComponent);
    NSArray<UIAction *> *extra = AIPMenuActions(bundleID, appName);
    if (extra.count == 0) return config;
    // SDK của Theos không khai báo property actionProvider của UIContextMenuConfiguration
    // (biên dịch bằng dot-syntax là chết lỗi) — truy cập qua objc_msgSend cho chắc.
    if (![config respondsToSelector:@selector(actionProvider)] || ![config respondsToSelector:@selector(setActionProvider:)]) {
        AIPLog(@"UIContextMenuConfiguration khong co actionProvider, bo qua");
        return config;
    }
    UIContextMenuActionProvider originalProvider = ((UIContextMenuActionProvider (*)(id, SEL))objc_msgSend)(config, @selector(actionProvider));
    UIContextMenuActionProvider newProvider = ^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        UIMenu *menu = originalProvider ? originalProvider(suggestedActions) : [UIMenu menuWithChildren:suggestedActions];
        if (!menu) menu = [UIMenu menuWithChildren:suggestedActions];
        NSMutableArray<UIMenuElement *> *children = [menu.children mutableCopy];
        [children addObjectsFromArray:extra];
        return [UIMenu menuWithTitle:menu.title image:menu.image identifier:menu.identifier options:menu.options children:children];
    };
    ((void (*)(id, SEL, UIContextMenuActionProvider))objc_msgSend)(config, @selector(setActionProvider:), newProvider);
    return config;
}

%end

#pragma mark - Khởi động

static void AIPPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    gPrefs = AIPLoadPrefs();
    AIPLog(@"Prefs thay doi, da nap lai (enabled=%@)", AIPMasterEnabled() ? @"YES" : @"NO");
}

%ctor {
    gPrefs = AIPLoadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, AIPPrefsChangedCallback, (__bridge CFStringRef)AIPPrefsChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    BOOL hasMenuMethod = class_getInstanceMethod(NSClassFromString(@"SBIconView"), @selector(contextMenuInteraction:configurationForMenuAtLocation:)) != NULL;
    AIPLog(@"AppInfoPress (SpringBoard) da nap — enabled=%@, SBIconView co menu an giu: %@", AIPMasterEnabled() ? @"YES" : @"NO", hasMenuMethod ? @"CO" : @"KHONG");
}
