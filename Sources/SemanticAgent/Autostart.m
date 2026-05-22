#if DEBUG
#import <Foundation/Foundation.h>

extern void _semantic_agent_autostart(void);

@interface _SemanticAgentLoader : NSObject
@end

@implementation _SemanticAgentLoader
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        _semantic_agent_autostart();
    });
}
@end
#endif
