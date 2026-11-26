import SwiftUI

enum PlacementExample {
    static func draw(_ context: GraphicsContext, size: CGSize, scene: DemoScene, phase: CGFloat) {
        var ctx = context
        let screen = CGRect(origin: .zero, size: size)
        ctx.clip(to: Path(roundedRect: screen, cornerRadius: 6))
        let area = PreviewWindow.workArea(in: size)
        let (left, right) = area.divided(atDistance: area.width / 2, from: .minXEdge)
        let floating = PreviewWindow.floatingFrame(in: area)
        func ease(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let x = min(1, max(0, (phase-a)/(b-a)))
            return x*x*(3-2*x)
        }
        func between(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x:a.x+(b.x-a.x)*t, y:a.y+(b.y-a.y)*t)
        }
        // Keep the same point on the title bar under the pointer throughout the drag.
        func grip(_ r: CGRect) -> CGPoint { CGPoint(x:r.minX+0.42*r.width, y:r.minY+0.06*r.height) }
        func held(at p: CGPoint, size s: CGSize) -> CGRect {
            CGRect(x:p.x-0.42*s.width,y:p.y-0.06*s.height,width:s.width,height:s.height)
        }
        func slot(_ r: CGRect, color: Color = .accentColor) {
            let path = Path(roundedRect:r.insetBy(dx:2,dy:2),cornerRadius:4)
            ctx.fill(path,with:.color(color.opacity(0.13)))
            ctx.stroke(path,with:.color(color),style:StrokeStyle(lineWidth:1.4,dash:[4,3]))
        }
        let progress = ease(0.12,0.48)
        let dropped = phase >= 0.58
        var pointer = grip(floating)
        switch scene {
        case .restore:
            let previous = CGSize(width:137,height:75)
            let start = grip(area)
            pointer = between(start, CGPoint(x:start.x,y:start.y + area.height * 0.12), ease(0.12,0.41))
            let recovery = ease(0.12,0.32)
            let current = CGSize(width:area.width+(previous.width-area.width)*recovery,
                                 height:area.height+(previous.height-area.height)*recovery)
            PreviewWindow.draw(ctx,held(at:pointer,size:current),tint:.blue)
        case .replace, .assist, .subdivide:
            let subdivision: Bool = if case .subdivide = scene { true } else { false }
            let replacement: Bool = if case .replace = scene { true } else { false }
            let (upper, lower) = left.divided(atDistance:left.height/2,from:.minYEdge)
            let destination = subdivision ? upper : left
            let origin = subdivision ? left : floating
            let edge = CGPoint(x:2,y:subdivision ? 3 : area.midY)
            pointer = between(grip(origin),edge,progress)
            let shrink = subdivision ? ease(0.21,0.35) : 1
            let dragSize = CGSize(width:origin.width+(floating.width-origin.width)*shrink,
                                  height:origin.height+(floating.height-origin.height)*shrink)
            let tint: Color = replacement ? .orange : .blue
            if replacement { PreviewWindow.draw(ctx,left,tint:.blue) }
            if replacement || subdivision { PreviewWindow.draw(ctx,right,tint:.teal) }
            if phase >= 0.43 && !dropped {
                slot(destination, color: replacement ? .blue : .accentColor)
            }
            PreviewWindow.draw(ctx,dropped ? destination : held(at:pointer,size:dragSize),tint:tint)
            if dropped && !replacement {
                let empty = subdivision ? lower : right
                if subdivision {
                    let candidate = empty.insetBy(dx:empty.width*0.26,dy:empty.height*0.24)
                    let target = CGPoint(x:candidate.midX,y:candidate.midY)
                    pointer = between(edge,target,ease(0.61,0.75))
                    let selected = ease(0.79,0.87)
                    if selected < 1 { slot(empty) }
                    let card = candidate.insetBy(dx:-(candidate.minX-empty.minX)*selected,
                                                 dy:-(candidate.minY-empty.minY)*selected)
                    PreviewWindow.draw(ctx,card,tint:.orange)
                    if phase >= 0.77 && phase < 0.84 {
                        let radius = 3 + 9*ease(0.77,0.84)
                        let pulse = CGRect(x:target.x-radius,y:target.y-radius,width:2*radius,height:2*radius)
                        ctx.stroke(Path(ellipseIn:pulse),with:.color(.primary.opacity(1-ease(0.77,0.84))),lineWidth:1.4)
                    }
                } else if phase >= 0.75 {
                    let (top,bottom) = empty.divided(atDistance:empty.height/2,from:.minYEdge)
                    slot(top)
                    slot(bottom)
                    ctx.draw(Text("⌥").font(.system(size:14,weight:.bold)),at:CGPoint(x:right.midX,y:right.midY))
                } else {
                    slot(empty)
                }
            }
        default: return
        }
        ResizeExample.pointer(ctx,at:pointer)
    }
}
