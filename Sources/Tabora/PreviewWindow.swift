import SwiftUI

enum PreviewWindow {
    static let screenBackground = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let gray: CGFloat = dark ? 0.19 : 0.975
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    })
    static let screenSize = CGSize(width: 224, height: 140)

    static func workArea(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
    }

    static func floatingFrame(in area: CGRect) -> CGRect {
        CGRect(x: area.midX - 28, y: area.midY - 20, width: 86, height: 63)
    }

    static func drawGroup(_ ctx: GraphicsContext, area: CGRect, boundary: CGFloat, mode: String = "") {
        let left = CGRect(x: area.minX, y: area.minY, width: boundary - area.minX, height: area.height)
        let right = CGRect(x: boundary, y: area.minY, width: area.maxX - boundary, height: area.height)
        draw(ctx, left, tint: .blue, proxy: mode == "lightweight", icon: "doc.text.fill")
        draw(ctx, right, tint: .teal, proxy: ["lightweight","mainOnly"].contains(mode), icon: "photo.fill")
    }

    static func draw(_ ctx: GraphicsContext, _ rect: CGRect, tint: Color, proxy: Bool = false, icon: String = "app.fill") {
        guard rect.width > 0, rect.height > 0 else { return }
        var ctx = ctx
        let shape = Path(roundedRect:rect,cornerRadius:5)
        ctx.fill(shape,with:.color(Color(nsColor:.windowBackgroundColor)))
        ctx.fill(shape,with:.color(tint.opacity(0.13)))
        ctx.stroke(shape,with:.color(tint.opacity(0.65)),lineWidth:1)
        ctx.clip(to: shape)
        if proxy {
            ctx.draw(Image(systemName:icon),at:CGPoint(x:rect.midX,y:rect.midY))
            return
        }
        for i in 0..<3 {
            ctx.fill(Path(ellipseIn:CGRect(x:rect.minX+5+CGFloat(i)*4,y:rect.minY+5,width:2.6,height:2.6)),with:.color(tint.opacity(0.8)))
        }
        for (i, fraction) in [0.72,0.52,0.62].enumerated() {
            ctx.fill(Path(roundedRect:CGRect(x:rect.minX+7,y:rect.minY+18+CGFloat(i)*6,width:max(0,rect.width-14)*fraction,height:2.5),cornerRadius:1),with:.color(tint.opacity(0.55)))
        }
    }
}
