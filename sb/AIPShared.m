#import "AIPShared.h"
#import <objc/message.h>

NSString * const AIPPrefsDomain = @"com.anhdang.appinfopress";
NSString * const AIPPrefsChangedNotification = @"com.anhdang.appinfopress/prefsChanged";

// Khoá đồng bộ cho log (dùng 1 class riêng làm token).
@interface AIPSharedLock : NSObject
@end
@implementation AIPSharedLock
@end

#pragma mark - Log

void AIPLog(NSString *format, ...) {
    if (!AIPPrefEnabled(AIPLoadPrefs(), @"debug", YES)) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *process = [[NSProcessInfo processInfo] processName] ?: @"?";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", process, message];
    NSLog(@"[AppInfoPress] %@", message);
    @synchronized ([AIPSharedLock class]) {
        NSString *path = @"/var/mobile/Documents/AppInfoPress.log";
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    }
}

#pragma mark - Prefs

NSDictionary *AIPLoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)AIPPrefsDomain);
    NSDictionary *values = (__bridge_transfer NSDictionary *)CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)AIPPrefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return values ?: @{};
}

BOOL AIPPrefEnabled(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value boolValue];
    return fallback;
}

void AIPSetPrefValue(NSString *key, id value) {
    if (value) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)AIPPrefsDomain);
    } else {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)AIPPrefsDomain);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)AIPPrefsDomain);
}

#pragma mark - Tra app

static id AIPApplicationProxy(NSString *bundleID) {
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) return nil;
    id workspace = ((id (*)(id, SEL))objc_msgSend)(wsClass, @selector(defaultWorkspace));
    if (!workspace || ![workspace respondsToSelector:@selector(applicationProxyForIdentifier:)]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(workspace, @selector(applicationProxyForIdentifier:), bundleID);
}

NSURL *AIPDataContainerURLForBundleID(NSString *bundleID) {
    id proxy = AIPApplicationProxy(bundleID);
    if (proxy && [proxy respondsToSelector:@selector(dataContainerURL)]) {
        NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(proxy, @selector(dataContainerURL));
        if (url.path.length > 0) return url;
    }
    // Dự phòng: quét thư mục container, đọc metadata để khớp bundle id.
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:base error:nil] ?: @[]) {
        NSString *dir = [base stringByAppendingPathComponent:entry];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        if ([meta[@"MCMMetadataIdentifier"] isEqualToString:bundleID]) {
            return [NSURL fileURLWithPath:dir];
        }
    }
    return nil;
}

NSString *AIPAppNameForBundleID(NSString *bundleID, NSString *fallback) {
    id proxy = AIPApplicationProxy(bundleID);
    if (proxy && [proxy respondsToSelector:@selector(localizedName)]) {
        NSString *name = ((NSString *(*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName));
        if (name.length > 0) return name;
    }
    return fallback.length > 0 ? fallback : bundleID;
}

#pragma mark - Dung lượng / xoá dữ liệu

unsigned long long AIPSizeOfDirectory(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    for (NSString *relative in enumerator) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:[path stringByAppendingPathComponent:relative] error:nil];
        if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) {
            total += [attrs[NSFileSize] unsignedLongLongValue];
        }
    }
    return total;
}

unsigned long long AIPClearContentsOfDirectory(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) return 0;
    unsigned long long before = AIPSizeOfDirectory(path);
    for (NSString *entry in [fm contentsOfDirectoryAtPath:path error:nil] ?: @[]) {
        [fm removeItemAtPath:[path stringByAppendingPathComponent:entry] error:nil];
    }
    unsigned long long after = AIPSizeOfDirectory(path);
    return before > after ? before - after : 0;
}

long long AIPClearCacheForBundleID(NSString *bundleID) {
    NSURL *container = AIPDataContainerURLForBundleID(bundleID);
    if (!container) return -1;
    unsigned long long freed = 0;
    freed += AIPClearContentsOfDirectory([container.path stringByAppendingPathComponent:@"Library/Caches"]);
    freed += AIPClearContentsOfDirectory([container.path stringByAppendingPathComponent:@"tmp"]);
    return (long long)freed;
}

long long AIPResetDataForBundleID(NSString *bundleID) {
    NSURL *container = AIPDataContainerURLForBundleID(bundleID);
    if (!container) return -1;
    unsigned long long freed = 0;
    freed += AIPClearContentsOfDirectory([container.path stringByAppendingPathComponent:@"Documents"]);
    freed += AIPClearContentsOfDirectory([container.path stringByAppendingPathComponent:@"Library"]);
    freed += AIPClearContentsOfDirectory([container.path stringByAppendingPathComponent:@"tmp"]);
    return (long long)freed;
}

NSString *AIPByteString(unsigned long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    double kb = bytes / 1024.0;
    if (kb < 1024) return [NSString stringWithFormat:@"%.1f KB", kb];
    double mb = kb / 1024.0;
    if (mb < 1024) return [NSString stringWithFormat:@"%.1f MB", mb];
    return [NSString stringWithFormat:@"%.2f GB", mb / 1024.0];
}
