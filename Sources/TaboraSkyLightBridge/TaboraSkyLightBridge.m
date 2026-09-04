#import "TaboraSkyLightBridge.h"
#import "TaboraSkyLightMoveRuntime.h"

#import <dispatch/dispatch.h>
#import <dlfcn.h>

typedef int (*TSLSLSMainConnectionIDFunction)(void);
typedef CFArrayRef _Nullable (*TSLSLSCopySpacesForWindowsFunction)(
    int,
    int,
    CFArrayRef
);
typedef int (*TSLSSpaceGetTypeFunction)(int, uint64_t);
typedef CFStringRef _Nullable (*TSLSLSCopyManagedDisplayForSpaceFunction)(
    int,
    uint64_t
);
typedef CFArrayRef _Nullable (*TSLSLSCopyManagedDisplaySpacesFunction)(int);
typedef AXError (*TSLAXUIElementGetWindowFunction)(
    AXUIElementRef,
    uint32_t *
);

static const char *const TSLSkyLightLoadPath =
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight";

typedef struct {
    void *skyLightHandle;
    TSLSLSMainConnectionIDFunction mainConnectionID;
    TSLSLSCopySpacesForWindowsFunction copySpacesForWindows;
    TSLSSpaceGetTypeFunction spaceGetType;
    TSLSLSCopyManagedDisplayForSpaceFunction copyManagedDisplayForSpace;
    TSLSLSCopyManagedDisplaySpacesFunction copyManagedDisplaySpaces;
    TSLAXUIElementGetWindowFunction axGetWindow;
    TSLBridgeCapability capabilities;
} TSLRuntime;

static TSLRuntime TSLLoadRuntime(void) {
    TSLRuntime runtime = {0};
    runtime.skyLightHandle = dlopen(
        TSLSkyLightLoadPath,
        RTLD_LAZY | RTLD_LOCAL
    );
    if (!runtime.skyLightHandle) {
        return runtime;
    }

    runtime.mainConnectionID = (TSLSLSMainConnectionIDFunction)dlsym(
        runtime.skyLightHandle,
        "SLSMainConnectionID"
    );
    runtime.copySpacesForWindows =
        (TSLSLSCopySpacesForWindowsFunction)dlsym(
            runtime.skyLightHandle,
            "SLSCopySpacesForWindows"
        );
    runtime.spaceGetType = (TSLSSpaceGetTypeFunction)dlsym(
        runtime.skyLightHandle,
        "SLSSpaceGetType"
    );
    runtime.copyManagedDisplayForSpace =
        (TSLSLSCopyManagedDisplayForSpaceFunction)dlsym(
            runtime.skyLightHandle,
            "SLSCopyManagedDisplayForSpace"
        );
    runtime.copyManagedDisplaySpaces =
        (TSLSLSCopyManagedDisplaySpacesFunction)dlsym(
            runtime.skyLightHandle,
            "SLSCopyManagedDisplaySpaces"
        );
    runtime.axGetWindow = (TSLAXUIElementGetWindowFunction)dlsym(
        RTLD_DEFAULT,
        "_AXUIElementGetWindow"
    );
    if (runtime.axGetWindow) {
        runtime.capabilities |= TSLBridgeCapabilityResolveWindowID;
    }
    if (runtime.mainConnectionID && runtime.copySpacesForWindows) {
        runtime.capabilities |= TSLBridgeCapabilityReadWindowSpaces;
    }
    if (runtime.mainConnectionID && runtime.spaceGetType) {
        runtime.capabilities |= TSLBridgeCapabilityReadSpaceType;
    }
    if (runtime.mainConnectionID && runtime.copyManagedDisplayForSpace) {
        runtime.capabilities |= TSLBridgeCapabilityReadSpaceDisplay;
    }
    if (runtime.mainConnectionID && runtime.copyManagedDisplaySpaces) {
        runtime.capabilities |= TSLBridgeCapabilityReadManagedDisplaySpaces;
    }
    return runtime;
}

static const TSLRuntime *TSLSharedRuntime(void) {
    static TSLRuntime runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime = TSLLoadRuntime();
    });
    return &runtime;
}

TSLBridgeCapability TSLBridgeCopyCapabilities(void) {
    const TSLRuntime *runtime = TSLSharedRuntime();
    TSLBridgeCapability capabilities = runtime->capabilities;
    if (TSLMoveRuntimeIsAvailable()) {
        capabilities |= TSLBridgeCapabilityDispatchBridgedMove;
    }
    return capabilities;
}

TSLBridgeMoveRuntimeComponent TSLBridgeCopyMoveRuntimeComponents(void) {
    return TSLMoveRuntimeCopyComponents();
}

NSString *TSLBridgeCopyMoveRuntimeDiagnosticDescription(void) {
    return TSLMoveRuntimeCopyDiagnosticDescription();
}

BOOL TSLBridgeCopyWindowID(AXUIElementRef element, uint32_t *windowID) {
    if (!element || !windowID) {
        return NO;
    }
    const TSLRuntime *runtime = TSLSharedRuntime();
    if (!runtime->axGetWindow) {
        return NO;
    }
    uint32_t resolvedWindowID = 0;
    AXError result = runtime->axGetWindow(element, &resolvedWindowID);
    if (result != kAXErrorSuccess || resolvedWindowID == 0) {
        return NO;
    }
    *windowID = resolvedWindowID;
    return YES;
}

NSArray<NSNumber *> * _Nullable
TSLBridgeCopySpacesForWindowID(uint32_t windowID) {
    if (windowID == 0) {
        return nil;
    }
    const TSLRuntime *runtime = TSLSharedRuntime();
    if (!runtime->mainConnectionID || !runtime->copySpacesForWindows) {
        return nil;
    }
    NSArray<NSNumber *> *windows = @[@(windowID)];
    CFArrayRef spaces = runtime->copySpacesForWindows(
        runtime->mainConnectionID(),
        0x7,
        (__bridge CFArrayRef)windows
    );
    if (!spaces) {
        return nil;
    }
    NSArray *bridgedSpaces = CFBridgingRelease(spaces);
    NSMutableArray<NSNumber *> *validated = [NSMutableArray array];
    for (id value in bridgedSpaces) {
        if ([value isKindOfClass:NSNumber.class]) {
            [validated addObject:value];
        }
    }
    return [validated copy];
}

BOOL TSLBridgeCopySpaceType(uint64_t spaceID, NSInteger *spaceType) {
    if (spaceID == 0 || !spaceType) {
        return NO;
    }
    const TSLRuntime *runtime = TSLSharedRuntime();
    if (!runtime->mainConnectionID || !runtime->spaceGetType) {
        return NO;
    }
    *spaceType = runtime->spaceGetType(
        runtime->mainConnectionID(),
        spaceID
    );
    return YES;
}

NSString * _Nullable TSLBridgeCopyManagedDisplayForSpace(uint64_t spaceID) {
    if (spaceID == 0) {
        return nil;
    }
    const TSLRuntime *runtime = TSLSharedRuntime();
    if (!runtime->mainConnectionID
        || !runtime->copyManagedDisplayForSpace) {
        return nil;
    }
    CFStringRef display = runtime->copyManagedDisplayForSpace(
        runtime->mainConnectionID(),
        spaceID
    );
    return display ? CFBridgingRelease(display) : nil;
}

NSArray<NSDictionary *> * _Nullable TSLBridgeCopyManagedDisplaySpaces(void) {
    const TSLRuntime *runtime = TSLSharedRuntime();
    if (!runtime->mainConnectionID || !runtime->copyManagedDisplaySpaces) {
        return nil;
    }
    CFArrayRef topology = runtime->copyManagedDisplaySpaces(
        runtime->mainConnectionID()
    );
    if (!topology) {
        return nil;
    }
    NSArray *bridged = CFBridgingRelease(topology);
    NSMutableArray<NSDictionary *> *validated = [NSMutableArray array];
    for (id value in bridged) {
        if ([value isKindOfClass:NSDictionary.class]) {
            [validated addObject:value];
        }
    }
    return [validated copy];
}

BOOL TSLBridgeDispatchMoveWindows(
    NSArray<NSNumber *> *windowIDs,
    uint64_t destinationSpaceID
) {
    return TSLBridgeDispatchMoveWindowsDetailed(
        windowIDs,
        destinationSpaceID,
        NULL
    );
}

BOOL TSLBridgeDispatchMoveWindowsDetailed(
    NSArray<NSNumber *> *windowIDs,
    uint64_t destinationSpaceID,
    NSString * _Nullable * _Nullable diagnostic
) {
    return TSLMoveRuntimeDispatchWindows(
        windowIDs,
        destinationSpaceID,
        diagnostic
    );
}
