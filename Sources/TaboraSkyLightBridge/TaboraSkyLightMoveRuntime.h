#import "TaboraSkyLightBridge.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL TSLMoveRuntimeIsAvailable(void);
FOUNDATION_EXPORT TSLBridgeMoveRuntimeComponent
TSLMoveRuntimeCopyComponents(void);
FOUNDATION_EXPORT NSString *TSLMoveRuntimeCopyDiagnosticDescription(void);
FOUNDATION_EXPORT BOOL TSLMoveRuntimeDispatchWindows(
    NSArray<NSNumber *> *windowIDs,
    uint64_t destinationSpaceID,
    NSString * _Nullable * _Nullable diagnostic
);

NS_ASSUME_NONNULL_END
