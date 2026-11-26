import AppKit
import SwiftUI

enum ResizeExample {
    static func position(at elapsed: TimeInterval) -> CGFloat {
        let travel = 1.45
        let hold = 0.85
        // The center hold straddles the loop boundary. Only the return
        // sweep from right to left crosses the center at full speed.
        let cycle = 4 * travel + 3 * hold
        var phase = max(0, elapsed).truncatingRemainder(dividingBy: cycle) - hold / 2
        func ease(_ fraction: Double) -> Double {
            let t = fraction + 0.24 * fraction * (1 - fraction)
            return t * t * t * (10 + t * (-15 + 6 * t))
        }
        if phase <= 0 { return 0 }
        if phase < travel { return ease(phase / travel) }
        phase -= travel + hold
        if phase <= 0 { return 1 }
        if phase < 2 * travel { return 1 - 2 * ease(phase / (2 * travel)) }
        phase -= 2 * travel + hold
        if phase <= 0 { return -1 }
        return -1 + ease(min(1, phase / travel))
    }

    // Both window edges, the guide, the handle and the cursor share the same pixel coordinate.
    static func draw(_ ctx: GraphicsContext, size: CGSize, progress: CGFloat, mode: String, style: LinkedResizePresentationStyle, distance: CGFloat, showsMarks: Bool) {
        let area = PreviewWindow.workArea(in: size)
        let boundary = area.midX + area.width * 0.19 * progress
        PreviewWindow.drawGroup(ctx, area: area, boundary: boundary, mode: mode)

        // Match the active guide and pill in Tabora’s ResizeHandleOverlay.
        let scale: CGFloat = 0.65
        let accent = Color(nsColor: .controlAccentColor)
        if style.showsSharedBoundary {
            let thickness: CGFloat = style == .windows ? 6 : 3
            let w = thickness * scale
            ctx.fill(Path(roundedRect: CGRect(x:boundary-w/2,y:area.minY,width:w,height:area.height),cornerRadius:w/2),
                     with:.color(accent))
        }
        if style.showsCenterControl {
            let w = 7 * scale
            let h = 42 * scale
            let handle = Path(roundedRect:CGRect(x:boundary-w/2,y:area.midY-h/2,width:w,height:h),cornerRadius:w/2)
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.24), radius: 3 * scale, y: scale))
                layer.fill(handle, with: .color(accent))
            }
            ctx.stroke(handle, with:.color(.black.opacity(0.28)), lineWidth:0.5 * scale)
        }
        let hotspot = CGPoint(x:boundary, y:area.midY + (style == .windows ? 19 : 0))
        if showsMarks {
            for sign: CGFloat in [-1,1] {
                let center = CGPoint(x:hotspot.x+sign*(distance+4.10)*scale, y:hotspot.y-0.5*scale)
                let shape = triangle(center, sign:sign, scale:scale)
                ctx.fill(shape, with:.color(.black.opacity(0.94)))
                ctx.stroke(shape, with:.color(.white.opacity(0.96)), lineWidth:scale)
            }
        }
        pointer(ctx, at:hotspot)
    }

    static func pointer(_ ctx: GraphicsContext, at point: CGPoint) {
        // The first vertex is the hotspot, independent of cursor theme and image padding.
        let outline: [CGPoint] = [
            .zero, CGPoint(x:0.5,y:14), CGPoint(x:4,y:10.6),
            CGPoint(x:6.8,y:16.2), CGPoint(x:9.1,y:15), CGPoint(x:6.4,y:9.5),
            CGPoint(x:11,y:9.3)
        ]
        var path = Path()
        path.addLines(outline.map { CGPoint(x:point.x+$0.x,y:point.y+$0.y) })
        path.closeSubpath()
        ctx.fill(path, with:.color(.black))
        ctx.stroke(path, with:.color(.white), style:StrokeStyle(lineWidth:1, lineJoin:.round))
    }

    private static func triangle(_ center: CGPoint, sign: CGFloat, scale: CGFloat) -> Path {
        // Same depth, base and per-corner rounding as ResizeCursorAdornmentMetrics.
        let points = [(4.10,0.0),(-4.10,4.35),(-4.10,-4.35)].map {
            CGPoint(x:center.x+sign*$0.0*scale,y:center.y+$0.1*scale)
        }
        var path = Path()
        for i in points.indices {
            let vertex = points[i]
            func toward(_ other: CGPoint) -> CGPoint {
                let dx = other.x-vertex.x, dy = other.y-vertex.y
                let factor = (i == 0 ? 1.55 : 1.0)*scale/hypot(dx,dy)
                return CGPoint(x:vertex.x+dx*factor,y:vertex.y+dy*factor)
            }
            let entry = toward(points[(i+2)%3])
            if i == 0 { path.move(to:entry) } else { path.addLine(to:entry) }
            path.addQuadCurve(to:toward(points[(i+1)%3]),control:vertex)
        }
        path.closeSubpath()
        return path
    }
}
