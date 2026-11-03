#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern void OmniPluginInitialize(void);
extern void OmniPluginHandleURLString(const char * _Nonnull urlCStr);

static IMP orig_scene_openURLContexts = NULL;
static IMP orig_scene_willConnect = NULL;

static void swizzled_scene_openURLContexts(id self, SEL _cmd, UIScene *scene, NSSet<UIOpenURLContext *> *urlContexts) {
    NSMutableSet<UIOpenURLContext *> *remaining = [NSMutableSet set];
    for (UIOpenURLContext *ctx in urlContexts) {
        NSURL *u = ctx.URL;
        if (u && [[u.scheme lowercaseString] isEqualToString:@"omnicontainer"]) {
            NSString *s = u.absoluteString;
            dispatch_async(dispatch_get_main_queue(), ^{
                OmniPluginHandleURLString([s UTF8String]);
            });
        } else if (ctx) {
            [remaining addObject:ctx];
        }
    }
    if (remaining.count > 0 && orig_scene_openURLContexts != NULL) {
        ((void(*)(id, SEL, UIScene *, NSSet<UIOpenURLContext *> *))orig_scene_openURLContexts)(self, _cmd, scene, remaining);
    }
}

static void swizzled_scene_willConnect(id self, SEL _cmd, UIScene *scene, UISceneSession *session, UISceneConnectionOptions *connectionOptions) {
    if (orig_scene_willConnect != NULL) {
        ((void(*)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *))orig_scene_willConnect)(self, _cmd, scene, session, connectionOptions);
    }
    for (UIOpenURLContext *ctx in connectionOptions.URLContexts) {
        NSURL *u = ctx.URL;
        if (u && [[u.scheme lowercaseString] isEqualToString:@"omnicontainer"]) {
            NSString *s = u.absoluteString;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                OmniPluginHandleURLString([s UTF8String]);
            });
        }
    }
}

static void installOmniURLHooks(void) {
    Class cls = NSClassFromString(@"YTSceneDelegate");
    if (!cls) return;

    SEL selOpen = @selector(scene:openURLContexts:);
    Method mOpen = class_getInstanceMethod(cls, selOpen);
    if (mOpen) {
        orig_scene_openURLContexts = method_getImplementation(mOpen);
        method_setImplementation(mOpen, (IMP)swizzled_scene_openURLContexts);
    } else {
        class_addMethod(cls, selOpen, (IMP)swizzled_scene_openURLContexts, "v@:@@");
    }

    SEL selConnect = @selector(scene:willConnectToSession:options:);
    Method mConnect = class_getInstanceMethod(cls, selConnect);
    if (mConnect) {
        orig_scene_willConnect = method_getImplementation(mConnect);
        method_setImplementation(mConnect, (IMP)swizzled_scene_willConnect);
    }
}

__attribute__((constructor))
static void OmniPluginConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        installOmniURLHooks();
        OmniPluginInitialize();
    });
}
