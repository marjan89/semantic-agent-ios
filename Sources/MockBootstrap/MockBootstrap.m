#if DEBUG
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Swizzle URLSessionConfiguration.protocolClasses at +load time
// This runs before ANY Swift code, including @Injected property wrappers

static IMP original_protocolClasses = NULL;

static id mock_protocolClasses(id self, SEL _cmd) {
    NSArray *original = ((id(*)(id, SEL))original_protocolClasses)(self, _cmd);
    Class mockClass = NSClassFromString(@"MockURLProtocol");
    if (!mockClass) {
        NSString *execName = [[NSBundle mainBundle].infoDictionary objectForKey:@"CFBundleExecutable"];
        if (execName) {
            mockClass = NSClassFromString([NSString stringWithFormat:@"%@.MockURLProtocol", execName]);
        }
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
    // Autostart the agent after Swift runtime is ready
    dispatch_async(dispatch_get_main_queue(), ^{
        Class agentClass = NSClassFromString(@"SemanticAgent");
        if (!agentClass) {
            // Try with common module prefixes
            NSBundle *mainBundle = [NSBundle mainBundle];
            NSString *execName = [[mainBundle infoDictionary] objectForKey:@"CFBundleExecutable"];
            if (execName) {
                NSString *mangled = [NSString stringWithFormat:@"%@.SemanticAgent", execName];
                agentClass = NSClassFromString(mangled);
            }
        }
        if (agentClass) {
            id shared = [agentClass performSelector:@selector(shared)];
            if (shared) {
                [shared performSelector:@selector(start)];
                NSLog(@"[MockBootstrap] SemanticAgent auto-started");
            }
        }
    });
}

@end
#endif
