#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect screen = NSScreen.mainScreen.visibleFrame;
        CGFloat leftWidth = floor(screen.size.width * 0.58);
        NSRect left = NSMakeRect(NSMinX(screen), NSMinY(screen), leftWidth, NSHeight(screen));
        NSRect right = NSMakeRect(NSMaxX(left), NSMinY(screen), NSWidth(screen) - leftWidth, NSHeight(screen));
        if ([NSProcessInfo.processInfo.arguments containsObject:@"three"]) {
            CGFloat bottomHeight = floor(NSHeight(screen) / 2);
            right.origin.y += bottomHeight;
            right.size.height -= bottomHeight;
        }
        NSRect loose = NSMakeRect(NSMinX(screen) + 32, NSMinY(screen) + 32, 320, 310);
        NSArray<NSValue *> *frames = @[[NSValue valueWithRect:left], [NSValue valueWithRect:right],
                                       [NSValue valueWithRect:loose]];
        NSMutableArray<NSWindow *> *windows = [NSMutableArray new];
        for (NSUInteger i = 0; i < frames.count; i++) {
            NSWindow *window = [[NSWindow alloc] initWithContentRect:loose
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered defer:NO];
            window.tabbingMode = NSWindowTabbingModeDisallowed;
            window.title = [NSString stringWithFormat:@"Tabora placement fixture %lu", i];
            [window setFrame:frames[i].rectValue display:YES];
            [window orderFront:nil];
            [windows addObject:window];
        }
        [windows.firstObject makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
