import SwiftUI

struct SwipeDiagram: View {
    let progress: CGFloat
    enum Direction { case up, left, right }
    let direction: Direction

    static func position(_ time: CGFloat) -> CGFloat {
        let t = max(0, min(1, (time - 0.12) / 0.68))
        return t * t * t * (10 + t * (-15 + 6 * t))
    }

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let pad = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), cornerRadius: 7)
                ctx.fill(pad, with: .color(.primary.opacity(0.04)))
                ctx.stroke(pad, with: .color(.secondary.opacity(0.42)), lineWidth: 1)
                let now = Self.position(progress)
                for age in stride(from: 3, through: 0, by: -1) {
                    let previous = Self.position(progress - CGFloat(age) * 0.034)
                    let distance = abs(now - previous)
                    guard age == 0 || distance > 0.005 else { continue }
                    let opacity = age == 0 ? 0.83 : min(1, distance * 12) * (0.24 - Double(age) * 0.045)
                    let x = size.width * 0.5 + (direction == .up ? 0 : (previous - 0.5) * (direction == .left ? -41 : 41))
                    let y = size.height * 0.5 - (direction == .up ? (previous - 0.5) * 29 : 0)
                    for offset: CGFloat in [-6, 6] {
                        let diameter: CGFloat = 9
                        let finger = CGRect(x: x + offset - diameter / 2, y: y - diameter / 2 + (offset < 0 ? 2 : 0), width: diameter, height: diameter)
                        ctx.fill(Path(ellipseIn: finger), with: .color(.primary.opacity(opacity)))
                    }
                }
            }.frame(width: 84, height: 57)
            Text("⌥").font(.system(size: 13, weight: .medium))
        }
    }
}
