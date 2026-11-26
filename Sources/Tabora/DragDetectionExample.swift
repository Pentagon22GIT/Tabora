import SwiftUI

enum DragDetectionExample {
    static func draw(_ context: GraphicsContext, size: CGSize, scene: DemoScene, time: Double, settings: AppSettings) {
        var ctx = context
        let screen = CGRect(origin: .zero, size: size)
        ctx.clip(to: Path(roundedRect: screen, cornerRadius: 6))
        let area = PreviewWindow.workArea(in: size)
        // Model a 1440 × 900 pt desktop at the same aspect ratio as the canvas.
        let edge = settings.edgeThreshold * size.width / 1440
        let band = settings.cornerBand * size.height / 900
        let color = Color(red: 80/255, green: 141/255, blue: 229/255)
        let isDwell = if case .dwell = scene { true } else { false }
        let isCorner = if case .corner = scene { true } else { false }
        func ease(_ a: Double, _ b: Double) -> CGFloat {
            let t = max(0, min(1, (time-a)/(b-a)))
            return t*t*(3-2*t)
        }
        let region = CGRect(x: 0, y: 0, width: edge, height: isCorner ? band : size.height)
        if !isDwell {
            ctx.fill(Path(region), with: .color(color.opacity(0.42)))
            if isCorner {
                ctx.fill(Path(region.offsetBy(dx:0,dy:size.height-band)),with:.color(color.opacity(0.42)))
            }
        }
        let arrival = 1.45
        let wait = settings.sideDwellDuration
        let expanded = isDwell && settings.sideDwellExpansionEnabled && time >= arrival + wait
        let contact = size.height * 0.43
        let endX = isDwell ? edge : 1
        let x = area.midX + (endX-area.midX) * ease(0.25,arrival)
        var y = contact
        if isCorner { y += (2-contact) * ease(1.55,2.7) }
        if expanded { y += size.height * 0.28 * ease(arrival+wait+0.45,arrival+wait+1.35) }
        let (half, _) = area.divided(atDistance:area.width/2,from:.minXEdge)
        let (upper, lower) = half.divided(atDistance:half.height/2,from:.minYEdge)
        let target = expanded ? (y <= size.height/2 ? upper : lower) : (y <= band ? upper : half)
        let released = !isDwell && time >= 3.15
        let pointer = CGPoint(x:x,y:y)
        if !released {
            let floating = PreviewWindow.floatingFrame(in:area)
            PreviewWindow.draw(ctx, CGRect(x:x-floating.width*0.42,y:y-4,width:floating.width,height:floating.height), tint:.orange)
            if x <= edge + 0.000001 {
                func outline(_ rect: CGRect, active: Bool) {
                    let path = Path(roundedRect:rect.insetBy(dx:2,dy:2),cornerRadius:4)
                    var opacity = 1.0
                    let pulse = min(0.72, wait)
                    let remaining = arrival + wait - time
                    if isDwell && settings.sideDwellExpansionEnabled && remaining > 0 && remaining < pulse {
                        opacity -= 0.5 * pow(sin(.pi*3*remaining/pulse),2)
                    }
                    ctx.fill(path,with:.color(color.opacity((active ? 0.28 : 0.08)*opacity)))
                    ctx.stroke(path,with:.color(color.opacity((active ? 0.96 : 0.40)*opacity)),lineWidth:active ? 1.7 : 1)
                }
                if expanded { outline(target == upper ? lower : upper, active:false) }
                outline(target,active:true)
            }
        } else {
            PreviewWindow.draw(ctx,target,tint:.orange)
        }
        ResizeExample.pointer(ctx,at:pointer)
    }
}
