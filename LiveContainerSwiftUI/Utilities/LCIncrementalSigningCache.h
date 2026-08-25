//
//  LCIncrementalSigningCache.h
//  LiveContainer
//
//  P2-18: incremental signing cache keyed on a content hash of
//  the bundle's main executable. The previous code re-signed
//  the entire app on every launch, taking minutes for large
//  games. With the cache, we sign once and only re-sign when
//  the executable content hash changes (or the cert expires).
//
//  Cache format in the app-group UserDefaults:
//    LCIncrementalSigningCache = {
//      "<bundleId>:<containerFolder>": {
//        "execHash": "<sha256 of executable contents>",
//        "signedAt": <epoch>,
//        "certSHA": "<sha256 of the cert blob>",
//        "patchRev": <int>
//      },
//      ...
//    }
//
//  A cache hit short-circuits ZSigner entirely. A cache miss
//  falls through to the existing sign path; the post-sign hook
//  stores the new entry. An old entry whose certSHA no longer
//  matches the current cert is invalidated automatically.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCIncrementalSigningCache : NSObject

/// Set up the cache. Reads the app-group id; harmless if
/// the app group is unset (cache becomes a no-op).
+ (void)registerOnAppGroupID:(nullable NSString *)appGroupID;

/// Lowercase hex SHA-256 of the input bytes. Used to key
/// the cache and the cert blob.
+ (NSString *)sha256OfData:(NSData *)data;

/// Returns YES if the bundle's executable is already signed
/// with the current cert and the executable content hash
/// matches the cached hash. NO otherwise (cache miss or
/// stale entry).
+ (BOOL)isCachedForBundleID:(NSString *)bundleID
                containerFolder:(NSString *)folder
            executablePath:(NSString *)execPath
                    certSHA:(NSString *)certSHA;

/// Records a successful sign so subsequent lookups hit.
+ (void)markSignedForBundleID:(NSString *)bundleID
                containerFolder:(NSString *)folder
            executablePath:(NSString *)execPath
                    certSHA:(NSString *)certSHA
                    patchRev:(NSInteger)patchRev;

/// Invalidate all entries. Called when the cert changes
/// or the user explicitly resets.
+ (void)clear;

@end

NS_ASSUME_NONNULL_END
