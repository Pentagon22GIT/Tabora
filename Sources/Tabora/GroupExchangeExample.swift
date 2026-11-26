import SwiftUI

struct GroupExchangeExample {
    let time: CGFloat
    private var index: Int { min(2, Int(time / 2)) }
    var direction: SwipeDiagram.Direction { [.up, .left, .right][index] }
    var progress: CGFloat { min(1, max(0, (time - CGFloat(index) * 2 - 0.25) / 1.3)) }

    func draw(_ ctx: GraphicsContext, size: CGSize) {
        let area = PreviewWindow.workArea(in: size)
        let (left, right) = area.divided(atDistance: area.width/2, from: .minXEdge)
        let (tr, br) = right.divided(atDistance: right.height/2, from: .minYEdge)
        let (tl, bl) = left.divided(atDistance: left.height/2, from: .minYEdge)
        // Each layout tracks the same blue, teal and focused orange window.
        let layouts = [[left,tr,br], [left,br,tr], [tr,br,left], [tl,bl,right]]
        let stage = index
        let amount = SwipeDiagram.position(progress)
        let colors: [Color] = [.blue,.teal,.orange]
        for i in colors.indices {
            let a = layouts[stage][i], b = layouts[stage+1][i]
            let frame = CGRect(x:a.minX+(b.minX-a.minX)*amount, y:a.minY+(b.minY-a.minY)*amount,
                               width:a.width+(b.width-a.width)*amount, height:a.height+(b.height-a.height)*amount)
            PreviewWindow.draw(ctx, frame, tint: colors[i])
            if i == 2 {
                ctx.stroke(Path(roundedRect:frame.insetBy(dx:1,dy:1),cornerRadius:4),with:.color(.orange),lineWidth:1.5)
            }
        }
    }
}
