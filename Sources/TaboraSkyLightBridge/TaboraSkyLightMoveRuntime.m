#import "TaboraSkyLightMoveRuntime.h"
#import "TaboraMachOSymbolResolver.h"

#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

// Current SkyLight ABI returns an opaque 64-bit dispatch value. Completion is
// never inferred from it; the Swift transaction verifies actual membership.
typedef int64_t (*TSLSLSPerformBridgedOperationFunction)(id);

typedef NS_ENUM(NSUInteger, TSLPerformResolutionSource) {
    TSLPerformResolutionSourceNone = 0,
    TSLPerformResolutionSourceExport,
    TSLPerformResolutionSourceExactLocalSymbol,
};

static const char *const TSLSkyLightLoadPath =
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight";
static const char *const TSLSkyLightImagePaths[] = {
    "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
};
static const char *const TSLPerformExportName =
    "SLSPerformAsynchronousBridgedWindowManagementOperation";

// Maintenance boundary: only reviewed, exact ABI variants belong here. Never
// replace this allowlist with prefix/fuzzy lookup or an older move API.
static const char *const TSLPerformLocalSymbolName =
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
static const char *const TSLMoveOperationClassName =
    "SLSBridgedMoveWindowsToManagedSpaceOperation";
static const char *const TSLMoveOperationInitializerName =
    "initWithWindows:spaceID:";

@interface NSObject (TaboraSkyLightMoveOperation)
- (instancetype)initWithWindows:(NSArray<NSNumber *> *)windows
                         spaceID:(uint64_t)spaceID;
@end

typedef struct {
    void *skyLightHandle;
    TSLSLSPerformBridgedOperationFunction performBridgedOperation;
    TSLPerformResolutionSource performResolutionSource;
    const char *performResolvedName;
    const char *performResolutionImagePath;
    TSLMachOSymbolResolutionStatus localSymbolStatus;
    SEL operationInitializer;
} TSLMoveRuntime;

static TSLMoveRuntime TSLLoadMoveRuntime(void) {
    TSLMoveRuntime runtime = {0};
    runtime.localSymbolStatus =
        TSLMachOSymbolResolutionStatusImageMissing;
    runtime.skyLightHandle = dlopen(
        TSLSkyLightLoadPath,
        RTLD_LAZY | RTLD_LOCAL
    );
    if (!runtime.skyLightHandle) {
        return runtime;
    }

    runtime.performBridgedOperation =
        (TSLSLSPerformBridgedOperationFunction)dlsym(
            runtime.skyLightHandle,
            TSLPerformExportName
        );
    if (runtime.performBridgedOperation) {
        runtime.performResolutionSource = TSLPerformResolutionSourceExport;
        runtime.performResolvedName = TSLPerformExportName;
        runtime.performResolutionImagePath = TSLSkyLightLoadPath;
        runtime.localSymbolStatus = TSLMachOSymbolResolutionStatusResolved;
    } else {
        for (NSUInteger index = 0;
             index < sizeof(TSLSkyLightImagePaths)
                / sizeof(TSLSkyLightImagePaths[0]);
             index += 1) {
            TSLMachOSymbolResolutionStatus status =
                TSLMachOSymbolResolutionStatusImageMissing;
            void *resolved = TSLResolveLocalMachOSymbol(
                TSLSkyLightImagePaths[index],
                TSLPerformLocalSymbolName,
                &status
            );
            runtime.localSymbolStatus = status;
            runtime.performResolutionImagePath = TSLSkyLightImagePaths[index];
            if (resolved) {
                runtime.performBridgedOperation =
                    (TSLSLSPerformBridgedOperationFunction)resolved;
                runtime.performResolutionSource =
                    TSLPerformResolutionSourceExactLocalSymbol;
                runtime.performResolvedName = TSLPerformLocalSymbolName;
                break;
            }
            // The second spelling is useful only when the canonical dyld image
            // name was absent. Other failures describe that exact image.
            if (status != TSLMachOSymbolResolutionStatusImageMissing) {
                break;
            }
        }
    }
    runtime.operationInitializer = sel_registerName(
        TSLMoveOperationInitializerName
    );
    return runtime;
}

static const TSLMoveRuntime *TSLSharedMoveRuntime(void) {
    static TSLMoveRuntime runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime = TSLLoadMoveRuntime();
    });
    return &runtime;
}

static TSLBridgeMoveRuntimeComponent TSLCurrentMoveRuntimeComponents(
    const TSLMoveRuntime *runtime
) {
    TSLBridgeMoveRuntimeComponent components = 0;
    Class operationClass = objc_getClass(TSLMoveOperationClassName);
    if (runtime->performResolutionSource == TSLPerformResolutionSourceExport) {
        components |= TSLBridgeMoveRuntimeComponentPerformExport;
    } else if (runtime->performResolutionSource
               == TSLPerformResolutionSourceExactLocalSymbol) {
        components |= TSLBridgeMoveRuntimeComponentPerformLocalSymbol;
    }
    if (operationClass) {
        components |= TSLBridgeMoveRuntimeComponentOperationClass;
    }
    Method initializer = operationClass
        ? class_getInstanceMethod(
            operationClass,
            runtime->operationInitializer
        )
        : NULL;
    if (initializer) {
        components |= TSLBridgeMoveRuntimeComponentInitializer;
    }
    if (initializer && method_getNumberOfArguments(initializer) == 4) {
        char *returnType = method_copyReturnType(initializer);
        char *windowsType = method_copyArgumentType(initializer, 2);
        char *spaceType = method_copyArgumentType(initializer, 3);
        const char *returnCursor = returnType;
        const char *windowsCursor = windowsType;
        const char *spaceCursor = spaceType;
        const char *qualifiers = "rnNoORV";
        while (returnCursor && *returnCursor != '\0'
               && strchr(qualifiers, *returnCursor)) {
            returnCursor += 1;
        }
        while (windowsCursor && *windowsCursor != '\0'
               && strchr(qualifiers, *windowsCursor)) {
            windowsCursor += 1;
        }
        while (spaceCursor && *spaceCursor != '\0'
               && strchr(qualifiers, *spaceCursor)) {
            spaceCursor += 1;
        }
        BOOL abiMatches = returnCursor && returnCursor[0] == '@'
            && windowsCursor && windowsCursor[0] == '@'
            && spaceCursor
            && (spaceCursor[0] == 'Q' || spaceCursor[0] == 'q');
        free(returnType);
        free(windowsType);
        free(spaceType);
        if (abiMatches) {
            components |= TSLBridgeMoveRuntimeComponentInitializerABI;
        }
    }
    return components;
}

static NSString *TSLPerformResolutionSourceDescription(
    TSLPerformResolutionSource source
) {
    switch (source) {
        case TSLPerformResolutionSourceExport:
            return @"export";
        case TSLPerformResolutionSourceExactLocalSymbol:
            return @"exact-local-Mach-O";
        case TSLPerformResolutionSourceNone:
            return @"none";
    }
    return @"unknown";
}

TSLBridgeMoveRuntimeComponent TSLMoveRuntimeCopyComponents(void) {
    return TSLCurrentMoveRuntimeComponents(TSLSharedMoveRuntime());
}

BOOL TSLMoveRuntimeIsAvailable(void) {
    TSLBridgeMoveRuntimeComponent components =
        TSLMoveRuntimeCopyComponents();
    BOOL hasPerform = (components
        & (TSLBridgeMoveRuntimeComponentPerformExport
           | TSLBridgeMoveRuntimeComponentPerformLocalSymbol)) != 0;
    TSLBridgeMoveRuntimeComponent required =
        TSLBridgeMoveRuntimeComponentOperationClass
        | TSLBridgeMoveRuntimeComponentInitializer
        | TSLBridgeMoveRuntimeComponentInitializerABI;
    return hasPerform && (components & required) == required;
}

NSString *TSLMoveRuntimeCopyDiagnosticDescription(void) {
    const TSLMoveRuntime *runtime = TSLSharedMoveRuntime();
    TSLBridgeMoveRuntimeComponent components =
        TSLCurrentMoveRuntimeComponents(runtime);
    NSString *symbol = runtime->performResolvedName
        ? [NSString stringWithUTF8String:runtime->performResolvedName]
        : @"none";
    NSString *imagePath = runtime->performResolutionImagePath
        ? [NSString stringWithUTF8String:runtime->performResolutionImagePath]
        : @"none";
    NSString *image = [imagePath containsString:@"/Versions/A/"]
        ? @"Versions/A/SkyLight"
        : imagePath.lastPathComponent;
    return [NSString stringWithFormat:
        @"Move API source=%@ image=%@ symbol=%@ resolver=%@ class=%@ initializer=%@ ABI=%@",
        TSLPerformResolutionSourceDescription(
            runtime->performResolutionSource
        ),
        image,
        symbol,
        TSLMachOSymbolResolutionStatusDescription(
            runtime->localSymbolStatus
        ),
        (components & TSLBridgeMoveRuntimeComponentOperationClass)
            ? @"yes" : @"no",
        (components & TSLBridgeMoveRuntimeComponentInitializer)
            ? @"yes" : @"no",
        (components & TSLBridgeMoveRuntimeComponentInitializerABI)
            ? @"yes" : @"no"
    ];
}

BOOL TSLMoveRuntimeDispatchWindows(
    NSArray<NSNumber *> *windowIDs,
    uint64_t destinationSpaceID,
    NSString * _Nullable * _Nullable diagnostic
) {
    if (windowIDs.count == 0 || destinationSpaceID == 0) {
        if (diagnostic) *diagnostic = @"入力拒否: window/Spaceが空です";
        return NO;
    }
    for (NSNumber *windowID in windowIDs) {
        if (windowID.unsignedIntValue == 0) {
            if (diagnostic) *diagnostic = @"入力拒否: WindowID=0です";
            return NO;
        }
    }

    const TSLMoveRuntime *runtime = TSLSharedMoveRuntime();
    Class operationClass = objc_getClass(TSLMoveOperationClassName);
    if (!TSLMoveRuntimeIsAvailable() || !operationClass) {
        if (diagnostic) {
            *diagnostic = [@"runtime拒否: " stringByAppendingString:
                TSLMoveRuntimeCopyDiagnosticDescription()];
        }
        return NO;
    }

    @try {
        id allocated = [operationClass alloc];
        id operation = [allocated initWithWindows:windowIDs
                                          spaceID:destinationSpaceID];
        if (!operation) {
            if (diagnostic) {
                *diagnostic = @"operation生成失敗: initializerがnilを返しました";
            }
            return NO;
        }
        int64_t dispatchValue = runtime->performBridgedOperation(operation);
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:
                @"handoff完了: source=%@ opaqueResult=%lld",
                TSLPerformResolutionSourceDescription(
                    runtime->performResolutionSource
                ),
                (long long)dispatchValue
            ];
        }
        return YES;
    } @catch (NSException *exception) {
        if (diagnostic) {
            *diagnostic = [NSString stringWithFormat:
                @"例外拒否: %@",
                exception.name ?: @"unknown"
            ];
        }
        return NO;
    }
}
