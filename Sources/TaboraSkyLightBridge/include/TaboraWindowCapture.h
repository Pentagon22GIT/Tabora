#pragma once
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Optional, read-only recovery for transformed preview surfaces. Requires
/// screen-recording permission and an exact owner. Caller must hold the shared
/// preview admission slot off-main until this synchronous function returns.
FOUNDATION_EXPORT CGImageRef _Nullable TSLBridgeCreateFullSizeWindowImage(
    uint32_t windowID,
    pid_t ownerPID
) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
