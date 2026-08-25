//
//  LCCertExpiryParser.h
//  LiveContainerSwiftUI
//
//  P0-5 helper. The Swift `import Security` import does NOT
//  expose SecCertificateCopyValues (it's in a private SPI
//  header in iOS 26+) or kSecOIDX509V1ValidityNotAfter. We
//  drop down to ObjC and pull in Security/SecCertificate.h
//  + Security/SecCertificateOIDs.h explicitly so the Swift
//  bridge can see them.
//
//  Returns the notAfter NSDate of the leaf cert inside a P12,
//  or nil if the data isn't a valid P12 or the leaf has no
//  notAfter attribute.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCCertExpiryParser : NSObject
+ (nullable NSDate *)notAfterForP12Data:(NSData *)p12Data
                                password:(NSString *)password;
@end

NS_ASSUME_NONNULL_END
