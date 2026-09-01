import ApplicationServices
import CoreGraphics
import TaboraSkyLightBridge

/// Small replaceable boundary around the optional underscored AX resolver.
/// Failure is always non-authoritative: callers retain their existing public
/// AX/Window Server matching fallback and never infer that a window vanished.
struct RuntimeWindowIDResolver {
    var isAvailable: Bool {
        TSLBridgeCopyCapabilities().contains(.resolveWindowID)
    }

    func resolve(_ element: AXUIElement) -> CGWindowID? {
        var rawWindowID: UInt32 = 0
        guard TSLBridgeCopyWindowID(element, &rawWindowID),
              rawWindowID != 0 else { return nil }
        return CGWindowID(rawWindowID)
    }
}
