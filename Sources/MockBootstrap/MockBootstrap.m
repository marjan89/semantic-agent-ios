#if DEBUG
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Swizzle URLSessionConfiguration.protocolClasses at +load time
// This runs before ANY Swift code, including @Injected property wrappers

static IMP original_protocolClasses = NULL;

static id mock_protocolClasses(id self, SEL _cmd) {
    NSArray *original = ((id(*)(id, SEL))original_protocolClasses)(self, _cmd);
    Class mockClass = NSClassFromString(@"Naturkartan_4.MockURLProtocol");
    if (!mockClass) {
        // Try without module prefix
        mockClass = NSClassFromString(@"MockURLProtocol");
    }
    if (mockClass && ![original containsObject:mockClass]) {
        NSMutableArray *modified = [NSMutableArray arrayWithObject:mockClass];
        if (original) [modified addObjectsFromArray:original];
        return modified;
    }
    return original;
}

@interface MockBootstrap : NSObject
@end

@implementation MockBootstrap

+ (void)load {
    Method m = class_getInstanceMethod([NSURLSessionConfiguration class], @selector(protocolClasses));
    if (m) {
        original_protocolClasses = method_setImplementation(m, (IMP)mock_protocolClasses);
        NSLog(@"[MockBootstrap] protocolClasses swizzled via +load");
    }
}

@end
#endif
