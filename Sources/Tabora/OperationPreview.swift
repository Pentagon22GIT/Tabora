import AppKit
import SwiftUI

// Coordinates are normalized to the miniature desktop, with a top-left origin.
enum DemoScene {
    case eightWay, command(ShortcutAction), snap(CGRect), replace, subdivide, restore, resize(String), raise, assist, dwell, edge, corner
    case preview, launch, record, migrate, reassign, cache, delay, lock

    var usesDesktopPointer: Bool {
        switch self {
        case .edge, .corner, .dwell, .resize, .raise, .replace, .subdivide, .restore, .assist: return true
        default: return false
        }
    }

    var input: String {
        switch self {
        case .eightWay, .snap, .lock, .reassign: return "gesture"
        case .command: return "keyboard"
        case .assist: return "⌥"
        case .launch: return "person.crop.circle"
        case .record: return "plus.app"
        case .cache, .preview: return "rectangle.stack"
        case .dwell, .delay: return "clock"
        default: return "cursorarrow"
        }
    }
}

struct OperationPreview: View {
    let scene: DemoScene
    let title: String
    private let settings = AppSettings.shared
    private var showsCandidates: Bool {
        switch scene {
        case .eightWay, .reassign: return true
        default: return false
        }
    }
    private var isExchange: Bool { if case .lock = scene { return true }; return false }
    @State private var playing = false
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            start = Date()
            playing = true
        } label: {
            TimelineView(.animation(minimumInterval: (scene.usesDesktopPointer || scene.input == "gesture") ? 1 / 60 : 1 / 24, paused: !playing || reduceMotion)) { tick in
                let elapsed = tick.date.timeIntervalSince(start) * 1.2
                let time = playing && !reduceMotion ? max(0, elapsed) : 0
                let gestureCycle = time.truncatingRemainder(dividingBy: 3.8)
                let t: CGFloat = switch scene {
                case .eightWay, .reassign: playing && !reduceMotion ? min(max(0, gestureCycle - 0.3) / 1.45, 1.8) : 1.8
                case .snap: reduceMotion ? 1 : min(1, max(0, gestureCycle - 0.3) / 1.2)
                case .dwell: time.truncatingRemainder(dividingBy: 4.2 + settings.sideDwellDuration)
                case .edge, .corner: time.truncatingRemainder(dividingBy: 4.6)
                case .lock: time.truncatingRemainder(dividingBy: 7.05)
                case .assist:
                    // The split appears at 3.6 seconds. Hold it for 2 seconds.
                    min(1, time.truncatingRemainder(dividingBy: 5.6) / 4.8)
                case .replace, .subdivide, .restore: time.truncatingRemainder(dividingBy: 4.8) / 4.8
                case .raise: time.truncatingRemainder(dividingBy: 3.6) / 3.6
                case .resize: ResizeExample.position(at: time)
                default: playing && !reduceMotion ? min(1, max(0, (elapsed - 0.22) / 1.2)) : 1
                }
                HStack(spacing: 12) {
                    if !scene.usesDesktopPointer {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.055))
                        if scene.input == "gesture" {
                            if isExchange {
                                let step = GroupExchangeExample(time: t)
                                SwipeDiagram(progress: step.progress, direction: step.direction)
                            } else if case .reassign = scene {
                                SwipeDiagram(progress: t, direction: .left)
                            } else {
                                let up = if case .snap(let zone) = scene { zone.width > 0.8 } else { false }
                                SwipeDiagram(progress: t, direction: up ? .up : .right)
                            }
                        } else if scene.input.contains("⌥") {
                            Text(scene.input).font(.system(size: 17, weight: .medium, design: .rounded))
                                .offset(y: -4 * sin(t * .pi))
                        } else {
                            Image(systemName: scene.input).font(.system(size: 17))
                                .offset(x: 4 * sin(t * .pi))
                        }
                    }.frame(width: scene.input == "gesture" ? 94 : 58)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Canvas { context, size in
                        let phase = scene.input == "gesture" ? SwipeDiagram.position(t) : t * t * (3 - 2 * t)
                        draw(context, size, scene.usesDesktopPointer || isExchange || showsCandidates ? t : phase)
                    }.frame(width: (scene.usesDesktopPointer || scene.input == "gesture") ? PreviewWindow.screenSize.width : 160, height: (scene.usesDesktopPointer || scene.input == "gesture") ? PreviewWindow.screenSize.height : 100)
                    if !scene.usesDesktopPointer && scene.input != "gesture" {
                        Image(systemName: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(scene.usesDesktopPointer || scene.input == "gesture" ? 0 : 6)
                .background {
                    if !scene.usesDesktopPointer && scene.input != "gesture" {
                        RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035))
                    }
                }
                .onChange(of: elapsed >= 1.65) { done in if done && !scene.usesDesktopPointer && scene.input != "gesture" { playing = false } }
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            start = Date()
            playing = true
        }
        .onDisappear { playing = false }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(L10n.text("settings.preview.replay")))
        .help(L10n.text("settings.preview.replay"))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: CGFloat) {
        let blue = Color(red: 0.18, green: 0.43, blue: 0.76)
        let teal = Color(red: 0.13, green: 0.56, blue: 0.52)
        let small = CGRect(x: 0.26, y: 0.22, width: 0.47, height: 0.61)
        let left = CGRect(x: 0.03, y: 0.07, width: 0.46, height: 0.86)
        let right = left.offsetBy(dx: 0.48, dy: 0)
        let full = CGRect(x: 0.03, y: 0.07, width: 0.94, height: 0.86)
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: a.minX + (b.minX-a.minX)*t, y: a.minY + (b.minY-a.minY)*t,
                   width: a.width + (b.width-a.width)*t, height: a.height + (b.height-a.height)*t)
        }
        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX*size.width, y: r.minY*size.height, width: r.width*size.width, height: r.height*size.height)
        }
        func tile(_ r: CGRect, _ color: Color, _ content: Bool = true) {
            PreviewWindow.draw(ctx, rect(r), tint: color, proxy: !content)
        }
        func drawCandidates(in vacant: CGRect, firstTint: Color = .orange, secondTint: Color = .teal) {
            if t > 0.88 {
                var picker = ctx
                picker.opacity = min(1, (t-0.88)/0.2)
                let outline = Path(roundedRect: vacant, cornerRadius: 5)
                picker.fill(outline, with: .color(.secondary.opacity(0.12)))
                let cards = vacant.insetBy(dx: 8, dy: 7)
                let (first, second) = cards.divided(atDistance: cards.height/2, from: .minYEdge)
                PreviewWindow.draw(picker, first.insetBy(dx: 2, dy: 2), tint: firstTint)
                PreviewWindow.draw(picker, second.insetBy(dx: 2, dy: 2), tint: secondTint)
            }
        }
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(PreviewWindow.screenBackground))
        switch scene {
        case .command(let action):
            var target = full
            switch action {
            case .leftHalf: target = left
            case .rightHalf: target = right
            case .topHalf, .bottomHalf: target.size.height = 0.41
            case .topLeft, .bottomLeft: target = left; target.size.height = 0.41
            case .topRight, .bottomRight: target = right; target.size.height = 0.41
            case .maximize: break
            case .restoreLast: tile(mix(full,small),blue); return
            case .toggleSplitLock:
                tile(left,blue); tile(right,teal)
                ctx.draw(Image(systemName: t < 0.5 ? "lock.open.fill" : "lock.fill"), at: CGPoint(x:size.width/2,y:size.height/2))
                return
            }
            if [.bottomHalf,.bottomLeft,.bottomRight].contains(action) { target.origin.y = 0.52 }
            tile(mix(small,target),blue)
        case .eightWay:
            let progress = SwipeDiagram.position(t)
            let target = right
            let frame = CGRect(x: small.minX + (target.minX-small.minX)*progress,
                               y: small.minY + (target.minY-small.minY)*progress,
                               width: small.width + (target.width-small.width)*progress,
                               height: small.height + (target.height-small.height)*progress)
            tile(frame, blue)
            drawCandidates(in: rect(left))
        case .reassign:
            let area = PreviewWindow.workArea(in: size)
            let (focused, peer) = area.divided(atDistance: area.width / 2, from: .minXEdge)
            PreviewWindow.draw(ctx, peer, tint: .teal)
            if t < 1.08 {
                var source = ctx
                source.opacity = min(1, (1.08 - t) / 0.2)
                PreviewWindow.draw(source, focused, tint: .blue)
                source.stroke(Path(roundedRect: focused, cornerRadius: 5), with: .color(.accentColor), lineWidth: 2)
            }
            drawCandidates(in: focused, firstTint: .blue, secondTint: .orange)
        case .snap(let zone): tile(mix(small,zone), blue)
        case .replace, .subdivide, .restore, .assist:
            PlacementExample.draw(ctx, size: size, scene: scene, phase: t)
        case .dwell, .edge, .corner:
            DragDetectionExample.draw(ctx, size: size, scene: scene, time: t, settings: settings)
        case .resize(let choice):
            let mode = choice == "selectedMode" ? settings.linkedResizeDisplayMode.rawValue : choice
            ResizeExample.draw(ctx, size: size, progress: t, mode: mode, style: LinkedResizePresentationStyle(rawValue: mode) ?? settings.linkedResizePresentationStyle, distance: settings.resizeCursorAdornmentDistance, showsMarks: settings.resizeCursorAdornmentEnabled)
        case .raise:
            let area = PreviewWindow.workArea(in: size)
            let boundary = area.midX
            let front = PreviewWindow.floatingFrame(in: area)
            let groupIsFront = (0.31..<0.82).contains(t)
            if groupIsFront { PreviewWindow.draw(ctx, front, tint: .orange) }
            PreviewWindow.drawGroup(ctx, area: area, boundary: boundary)
            if !groupIsFront { PreviewWindow.draw(ctx, front, tint: .orange) }
            let hotspot = CGPoint(x: area.minX + area.width * 0.18, y: area.midY)
            if (0.26..<0.46).contains(t) {
                let pulse = (t - 0.26) / 0.20
                let radius = 4 + 14 * pulse
                let ring = Path(ellipseIn: CGRect(x: hotspot.x - radius, y: hotspot.y - radius,
                                                  width: 2 * radius, height: 2 * radius))
                ctx.fill(ring, with: .color(.white.opacity(0.23 * (1 - pulse))))
                ctx.stroke(ring, with: .color(.black.opacity(0.5 * (1 - pulse))), lineWidth: 3)
                ctx.stroke(ring, with: .color(.white.opacity(1 - pulse)), lineWidth: 1.6)
            }
            ResizeExample.pointer(ctx, at: hotspot)
        case .lock:
            GroupExchangeExample(time: t).draw(ctx, size: size)
        case .migrate: tile(left,.gray.opacity(0.3)); tile(right,.gray.opacity(0.3)); tile(CGRect(x:0.07+0.48*t,y:0.29,width:0.16,height:0.42),blue); tile(CGRect(x:0.24+0.48*t,y:0.29,width:0.16,height:0.42),teal)
        case .launch:
            ctx.draw(Image(systemName:"person.crop.circle"), at:CGPoint(x:size.width*0.18,y:size.height/2))
            if t > 0.25 { tile(CGRect(x:0.32,y:0.18,width:0.61*t,height:0.68),blue) }
        case .preview:
            tile(left,blue)
            tile(right,teal.opacity(0.3),false)
            if t > 0.35 { tile(right,blue.opacity(t)) }
        case .record:
            tile(full,teal)
            if t > 0.3 {
                tile(small,blue)
                ctx.draw(Text("?").foregroundColor(.white),at:CGPoint(x:size.width*0.55,y:size.height*0.55))
            }
        case .cache:
            for i in 0..<Int(1+4*t) {
                tile(CGRect(x:0.08+CGFloat(i)*0.13,y:0.1+CGFloat(i)*0.08,width:0.35,height:0.55),i.isMultiple(of:2) ? blue : teal)
            }
        case .delay:
            tile(left,blue); tile(right,teal.opacity(0.25))
            ctx.draw(Image(systemName:"clock"),at:CGPoint(x:size.width*0.48,y:size.height/2))
            ctx.fill(Path(rect(CGRect(x:0.18,y:0.78,width:0.26*t,height:0.06))),with:.color(.white))
        }
    }
}
