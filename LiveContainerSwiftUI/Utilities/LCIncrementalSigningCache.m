//
//  LCIncrementalSigningCache.m
//  LiveContainer
//

#import "LCIncrementalSigningCache.h"
#import <CommonCrypto/CommonDigest.h>

static NSString * const kCacheKey = @"LCIncrementalSigningCache";

@implementation LCIncrementalSigningCache

+ (void)registerOnAppGroupID:(NSString *)appGroupID {
    // The cache is read on demand; nothing to do at register time.
    // This entry point exists so the host can call it explicitly
    // before the first sign; if the host never calls it, the
    // isCachedFor* methods simply always return NO.
    (void)appGroupID;
}

// P2-18 (build fix): C-linkage entry point. The host target calls
// this from main() before any other code runs. The original
// +load-style hook on LCSharedUtils broke the link because the
// LCIncrementalSigningCache class is in the LiveContainer target
// while LCSharedUtils compiles into the LiveContainerShared
// framework — a cross-target reference.
#ifdef __cplusplus
extern "C" {
#endif
// Default visibility: the host binary (LiveContainer/main.c) calls
// this. iOS frameworks compile with -fvisibility=hidden by default,
// so the linker can't find a non-static symbol from a framework's
// .o files. Mark it explicitly.
__attribute__((visibility("default")))
void LCIncrementalSigningCache_register(void) {
    // Read the app group from standard defaults. Best-effort: if
    // it isn't set yet, the cache is a no-op and lazily
    // self-registers on the first read.
    NSString *gid = [[NSUserDefaults standardUserDefaults] stringForKey:@"LCAppGroupID"];
    [LCIncrementalSigningCache registerOnAppGroupID:gid];
}
#ifdef __cplusplus
}
#endif

+ (NSUserDefaults *)defaults {
    NSString *gid = [[NSUserDefaults standardUserDefaults] stringForKey:@"LCAppGroupID"];
    if (gid.length == 0) {
        gid = @"group.com.kdt.livecontainer";
    }
    return [[NSUserDefaults alloc] initWithSuiteName:gid];
}

+ (NSString *)sha256OfFileAtPath:(NSString *)path error:(NSError **)error {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path]
                                                            error:error];
    if (!fh) { return nil; }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (1) {
        @autoreleasepool {
            NSData *chunk = [fh readDataOfLength:64 * 1024];
            if (chunk.length == 0) break;
            CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [fh closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

+ (NSString *)sha256OfData:(NSData *)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

+ (NSString *)cacheKeyForBundleID:(NSString *)bid folder:(NSString *)folder {
    return [NSString stringWithFormat:@"%@:%@", bid ?: @"?", folder];
}

+ (BOOL)isCachedForBundleID:(NSString *)bundleID
              containerFolder:(NSString *)folder
                executablePath:(NSString *)execPath
                       certSHA:(NSString *)certSHA {
    if (bundleID.length == 0 || folder.length == 0 || execPath.length == 0) {
        return NO;
    }
    NSDictionary *cache = [[self defaults] dictionaryForKey:kCacheKey];
    NSDictionary *entry = cache[[self cacheKeyForBundleID:bundleID folder:folder]];
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSString *cachedHash = entry[@"execHash"];
    NSString *cachedCert = entry[@"certSHA"];
    if (certSHA.length > 0 && ![cachedCert isEqualToString:certSHA]) {
        return NO;
    }
    NSError *err = nil;
    NSString *currentHash = [self sha256OfFileAtPath:execPath error:&err];
    if (!currentHash) {
        return NO;
    }
    return [cachedHash isEqualToString:currentHash];
}

+ (void)markSignedForBundleID:(NSString *)bundleID
              containerFolder:(NSString *)folder
                executablePath:(NSString *)execPath
                       certSHA:(NSString *)certSHA
                       patchRev:(NSInteger)patchRev {
    if (bundleID.length == 0 || folder.length == 0 || execPath.length == 0) {
        return;
    }
    NSError *err = nil;
    NSString *currentHash = [self sha256OfFileAtPath:execPath error:&err];
    if (!currentHash) {
        return;
    }
    NSMutableDictionary *cache = [[[self defaults] dictionaryForKey:kCacheKey] mutableCopy];
    if (!cache) cache = [NSMutableDictionary dictionary];
    cache[[self cacheKeyForBundleID:bundleID folder:folder]] = @{
        @"execHash": currentHash,
        @"certSHA": certSHA ?: @"",
        @"patchRev": @(patchRev),
        @"signedAt": @([[NSDate date] timeIntervalSince1970])
    };
    [[self defaults] setObject:cache forKey:kCacheKey];
}

+ (void)clear {
    [[self defaults] removeObjectForKey:kCacheKey];
}

@end
