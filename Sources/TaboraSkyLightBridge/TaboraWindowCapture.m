#import "TaboraWindowCapture.h"

#import <dispatch/dispatch.h>
#import <dlfcn.h>

typedef int (*TSLSLSMainConnectionIDFunction)(void);
typedef CFArrayRef _Nullable (*TSLHWCaptureWindowListFunction)(
    int, uint32_t *, int, uint32_t
);

// Independent read-only runtime: capturing never initializes Space migration.
typedef struct {
    void *skyLightHandle;
    TSLSLSMainConnectionIDFunction mainConnectionID;
    TSLHWCaptureWindowListFunction captureWindowList;
} TSLCaptureRuntime;

static const TSLCaptureRuntime *TSLSharedCaptureRuntime(void) {
    static TSLCaptureRuntime runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime.skyLightHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        );
        if (!runtime.skyLightHandle) { return; }
        runtime.mainConnectionID = (TSLSLSMainConnectionIDFunction)dlsym(
            runtime.skyLightHandle, "SLSMainConnectionID"
        );
        runtime.captureWindowList = (TSLHWCaptureWindowListFunction)dlsym(
            runtime.skyLightHandle, "SLSHWCaptureWindowList"
        );
        if (!runtime.captureWindowList) {
            runtime.captureWindowList = (TSLHWCaptureWindowListFunction)dlsym(
                runtime.skyLightHandle, "CGSHWCaptureWindowList"
            );
        }
    });
    return &runtime;
}

static BOOL TSLPreviewWindowHasOwner(uint32_t windowID, pid_t ownerPID) {
    NSArray *ids = @[@(windowID)];
    CFArrayRef descriptions = CGWindowListCreateDescriptionFromArray(
        (__bridge CFArrayRef)ids
    );
    if (!descriptions) { return NO; }
    BOOL matches = NO;
    if (CFArrayGetCount(descriptions) == 1) {
        NSDictionary *record = (__bridge NSDictionary *)CFArrayGetValueAtIndex(
            descriptions, 0
        );
        NSNumber *number = record[(__bridge NSString *)kCGWindowNumber];
        NSNumber *pid = record[(__bridge NSString *)kCGWindowOwnerPID];
        NSNumber *layer = record[(__bridge NSString *)kCGWindowLayer];
        matches = number && pid && layer
            && number.unsignedIntValue == windowID
            && pid.intValue == ownerPID && layer.intValue == 0;
    }
    CFRelease(descriptions);
    return matches;
}

CGImageRef TSLBridgeCreateFullSizeWindowImage(
    uint32_t windowID, pid_t ownerPID
) {
    @autoreleasepool {
        // No TCC prompt and no capture on the event/UI thread. The existing legacy
        // path remains available when this optional recovery cannot be used.
        if (!windowID || ownerPID <= 0 || [NSThread isMainThread]
            || !CGPreflightScreenCaptureAccess()) { return NULL; }
        const TSLCaptureRuntime *runtime = TSLSharedCaptureRuntime();
        if (!runtime->mainConnectionID || !runtime->captureWindowList) {
            return NULL;
        }
        int connection = runtime->mainConnectionID();
        if (!connection || !TSLPreviewWindowHasOwner(windowID, ownerPID)) {
            return NULL;
        }
        // Observed SPI option values, not CGWindowImageOption bits. In particular,
        // best resolution alone does not request an untransformed full-size image.
        // Reference: AltTab src/macos/api-wrappers/SkyLight.framework.swift
        // (ignoreGlobalClipShape, bestResolution, fullSize). No guessed arguments,
        // transform mutation, connection escalation or private stream is used.
        const uint32_t ignoreGlobalClipShape = 1U << 11;
        const uint32_t bestResolution = 1U << 8;
        const uint32_t fullSize = 1U << 19;
        CFArrayRef images = runtime->captureWindowList(
            connection, &windowID, 1,
            ignoreGlobalClipShape | bestResolution | fullSize
        );
        if (!images) { return NULL; }
        CGImageRef result = NULL;
        if (CFGetTypeID(images) == CFArrayGetTypeID()
            && CFArrayGetCount(images) == 1) {
            CFTypeRef value = CFArrayGetValueAtIndex(images, 0);
            if (value && CFGetTypeID(value) == CGImageGetTypeID()
                && CGImageGetWidth((CGImageRef)value) > 1
                && CGImageGetHeight((CGImageRef)value) > 1
                && CGPreflightScreenCaptureAccess()
                && TSLPreviewWindowHasOwner(windowID, ownerPID)) {
                result = CGImageRetain((CGImageRef)value);
            }
        }
        CFRelease(images);
        return result;
    }
}
