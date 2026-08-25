//
//  LCCertExpiryParser.m
//  LiveContainerSwiftUI
//

#import "LCCertExpiryParser.h"
#import <Security/SecCertificateOIDs.h>
#import <Security/SecCertificate.h>

@implementation LCCertExpiryParser

+ (nullable NSDate *)notAfterForP12Data:(NSData *)p12Data
                                password:(NSString *)password {
    NSDictionary *options = @{
        (__bridge id)kSecImportExportPassphrase: password ?: @""
    };
    CFArrayRef rawItems = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)p12Data,
                                      (__bridge CFDictionaryRef)options,
                                      &rawItems);
    if (status != errSecSuccess || rawItems == NULL) {
        return nil;
    }
    NSArray *items = (__bridge_transfer NSArray *)rawItems;
    for (NSDictionary *item in items) {
        SecIdentityRef identity = (__bridge SecIdentityRef)item[(__bridge id)kSecImportItemIdentity];
        if (identity == NULL) continue;
        SecCertificateRef cert = NULL;
        OSStatus certStatus = SecIdentityCopyCertificate(identity, &cert);
        if (certStatus != errSecSuccess || cert == NULL) continue;

        CFErrorRef cfErr = NULL;
        CFDictionaryRef values = SecCertificateCopyValues(
            cert,
            (__bridge CFArrayRef)@[(__bridge id)kSecOIDX509V1ValidityNotAfter],
            &cfErr
        );
        NSDate *result = nil;
        if (values) {
            NSDictionary *entry = (__bridge NSDictionary *)values;
            NSDictionary *notAfter = entry[(__bridge id)kSecOIDX509V1ValidityNotAfter];
            id value = notAfter[@"value"];
            if ([value isKindOfClass:[NSString class]]) {
                NSString *str = (NSString *)value;
                NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
                f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
                result = [f dateFromString:str];
                if (!result) {
                    f.formatOptions = NSISO8601DateFormatWithInternetDateTime;
                    result = [f dateFromString:str];
                }
            }
            CFRelease(values);
        }
        if (cfErr) CFRelease(cfErr);
        CFRelease(cert);
        if (result) return result;
    }
    return nil;
}

@end
