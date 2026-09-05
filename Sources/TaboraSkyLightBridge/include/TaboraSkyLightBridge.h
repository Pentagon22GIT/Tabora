#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, TSLBridgeCapability) {
    TSLBridgeCapabilityResolveWindowID = 1 << 0,
    TSLBridgeCapabilityReadWindowSpaces = 1 << 1,
    TSLBridgeCapabilityReadSpaceType = 1 << 2,
    TSLBridgeCapabilityReadSpaceDisplay = 1 << 3,
    TSLBridgeCapabilityDispatchBridgedMove = 1 << 4,
    TSLBridgeCapabilityReadManagedDisplaySpaces = 1 << 5,
};

typedef NS_OPTIONS(NSUInteger, TSLBridgeMoveRuntimeComponent) {
    TSLBridgeMoveRuntimeComponentPerformExport = 1 << 0,
    TSLBridgeMoveRuntimeComponentPerformLocalSymbol = 1 << 1,
    TSLBridgeMoveRuntimeComponentOperationClass = 1 << 2,
    TSLBridgeMoveRuntimeComponentInitializer = 1 << 3,
    TSLBridgeMoveRuntimeComponentInitializerABI = 1 << 4,
};

FOUNDATION_EXPORT TSLBridgeCapability TSLBridgeCopyCapabilities(void);
FOUNDATION_EXPORT TSLBridgeMoveRuntimeComponent
TSLBridgeCopyMoveRuntimeComponents(void);
FOUNDATION_EXPORT NSString *TSLBridgeCopyMoveRuntimeDiagnosticDescription(
    void
);

FOUNDATION_EXPORT BOOL TSLBridgeCopyWindowID(
    AXUIElementRef element,
    uint32_t *windowID
);

FOUNDATION_EXPORT NSArray<NSNumber *> * _Nullable
TSLBridgeCopySpacesForWindowID(uint32_t windowID);

FOUNDATION_EXPORT BOOL TSLBridgeCopySpaceType(
    uint64_t spaceID,
    NSInteger *spaceType
);

FOUNDATION_EXPORT NSString * _Nullable
TSLBridgeCopyManagedDisplayForSpace(uint64_t spaceID);

/// Read-only managed-display/Space topology. The returned dictionaries are
/// copied from SkyLight and treated as observation evidence only.
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable
TSLBridgeCopyManagedDisplaySpaces(void);

/// Returns YES only when the bridged operation was constructed and handed to
/// WindowServer. Completion must be verified by observing actual membership.
FOUNDATION_EXPORT BOOL TSLBridgeDispatchMoveWindows(
    NSArray<NSNumber *> *windowIDs,
    uint64_t destinationSpaceID
);

/// Detailed variant used for failure reporting. `diagnostic` describes whether
/// rejection happened during input validation, runtime resolution, operation
/// construction, or dispatch. A YES result still means hand-off only.
FOUNDATION_EXPORT BOOL TSLBridgeDispatchMoveWindowsDetailed(
    NSArray<NSNumber *> *windowIDs,
    uint64_t destinationSpaceID,
    NSString * _Nullable * _Nullable diagnostic
);

NS_ASSUME_NONNULL_END
