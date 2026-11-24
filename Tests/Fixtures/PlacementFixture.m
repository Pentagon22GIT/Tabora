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
        if ([NSProcessInfo.processInfo.arguments containsObject:@"four"]) {
            frames = [frames arrayByAddingObject:[NSValue valueWithRect:NSOffsetRect(loose, 60, 60)]];
        }
        NSMutableArray<NSWindow *> *windows = [NSMutableArray new];
        for (NSUInteger i = 0; i < frames.count; i++) {
            NSWindow *window = [[NSWindow alloc] initWithContentRect:loose
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered defer:NO];
            window.tabbingMode = NSWindowTabbingModeDisallowed;
            window.title = [NSString stringWithFormat:@"Tabora placement fixture %lu", i];
            BOOL overlap = [NSProcessInfo.processInfo.arguments containsObject:@"overlap"];
            if (overlap) window.title = @"Identical fixture";
            [window setFrame:overlap ? loose : frames[i].rectValue display:YES];
            [window orderFront:nil];
            [windows addObject:window];
        }
        [windows.firstObject makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
