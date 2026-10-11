import SwiftUI

struct PetRootView: View {
    @ObservedObject var model: PetModel
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let permission = model.permission {
                PermissionBubbleView(model: model, bubble: permission)
                    .transition(.scale(scale: 0.8, anchor: .bottomTrailing).combined(with: .opacity))
            } else if let info = model.info {
                InfoBubbleView(model: model, bubble: info)
                    .transition(.scale(scale: 0.8, anchor: .bottomTrailing).combined(with: .opacity))
            }
            PetCharacter(mood: model.mood, badge: model.pendingCount, skin: model.skin)
                .frame(width: 92, height: 92)
                .contentShape(Rectangle())
                .help(model.statusLine)
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { onDrag($0.translation) }
                        .onEnded { _ in onDragEnd() }
                )
                .onTapGesture {
                    model.open(agent: model.permission?.agent ?? model.info?.agent)
                    model.dismissInfo()
                }
        }
        .padding(6)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.info)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.permission)
        .fixedSize()
    }
}

// MARK: Bubbles

private struct BubbleFrame<Content: View>: View {
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(width: 280, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.opacity(0.55), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(.trailing, 30)
    }
}

private struct BubbleHeader: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String?
    let onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private func projectName(_ agent: PetAgent) -> String {
    "\(agent.provider) · \(URL(fileURLWithPath: agent.cwd).lastPathComponent)"
}

private struct InfoBubbleView: View {
    @ObservedObject var model: PetModel
    let bubble: InfoBubble

    var body: some View {
        let style: (String, Color, String) = switch bubble.kind {
        case .completed: ("checkmark.circle.fill", .green, bubble.agent?.title ?? "작업 완료")
        case .failed: ("exclamationmark.triangle.fill", .red, bubble.agent?.title ?? "작업 실패")
        case .system: ("pawprint.fill", .accentColor, "Paseo Pet")
        }
        BubbleFrame(accent: style.1) {
            VStack(alignment: .leading, spacing: 6) {
                BubbleHeader(
                    icon: style.0,
                    color: style.1,
                    title: style.2,
                    subtitle: bubble.agent.map(projectName),
                    onClose: { model.dismissInfo() }
                )
                Text(bubble.text)
                    .font(.system(size: 12))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if bubble.agent != nil {
                    Button("Paseo에서 보기") {
                        model.open(agent: bubble.agent)
                        model.dismissInfo()
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct PermissionBubbleView: View {
    @ObservedObject var model: PetModel
    let bubble: PermissionBubble

    private var answerable: Bool { bubble.permission.kind != "question" }
    private var busy: Bool { model.busyRequestId == bubble.permission.requestId }

    var body: some View {
        BubbleFrame(accent: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                BubbleHeader(
                    icon: "hand.raised.fill",
                    color: .orange,
                    title: "\(bubble.agent.title) · 승인 필요",
                    subtitle: projectName(bubble.agent),
                    onClose: nil
                )
                Text(bubble.permission.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                if let detail = bubble.permission.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(4)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
                if let error = model.lastError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Button("나중에") { model.later(bubble) }
                    Spacer()
                    if answerable {
                        Button("거절") { model.respond(bubble, allow: false) }
                            .disabled(busy)
                        Button("허용") { model.respond(bubble, allow: true) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(busy)
                    } else {
                        Button("Paseo에서 답하기") { model.open(agent: bubble.agent) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: Character

struct PetCharacter: View {
    let mood: PetMood
    let badge: Int
    var skin: Skin? = nil

    private var palette: (Color, Color) {
        switch mood {
        case .sleeping: (Color(red: 0.72, green: 0.70, blue: 0.90), Color(red: 0.55, green: 0.52, blue: 0.80))
        case .idle: (Color(red: 0.55, green: 0.88, blue: 0.78), Color(red: 0.25, green: 0.70, blue: 0.62))
        case .working: (Color(red: 0.55, green: 0.76, blue: 1.00), Color(red: 0.25, green: 0.50, blue: 0.95))
        case .waiting: (Color(red: 1.00, green: 0.80, blue: 0.45), Color(red: 0.98, green: 0.55, blue: 0.20))
        case .happy: (Color(red: 0.75, green: 0.95, blue: 0.50), Color(red: 0.40, green: 0.80, blue: 0.30))
        case .sad: (Color(red: 0.70, green: 0.76, blue: 0.86), Color(red: 0.45, green: 0.52, blue: 0.66))
        }
    }

    var body: some View {
        let interval: Double = (mood == .sleeping || mood == .idle) ? 1.0 / 15 : 1.0 / 30
        TimelineView(.animation(minimumInterval: interval)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Ellipse()
                    .fill(.black.opacity(0.18))
                    .frame(width: 54 - lift(t) * 0.8, height: 8)
                    .offset(y: 40)
                let moving = skin?.motion ?? true
                Group {
                    if let skin, skin.isSprite, let frame = skin.image(for: mood, at: t) {
                        Image(nsImage: frame)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 92, height: 92)
                    } else if let image = skin?.image(for: mood) {
                        SkinImage(image: image).frame(width: 84, height: 84)
                    } else {
                        figure(t)
                    }
                }
                .offset(y: moving ? -lift(t) : 0)
                .rotationEffect(.degrees(moving ? tilt(t) : 0), anchor: .bottom)
                .scaleEffect(x: 1, y: moving ? breathe(t) : 1, anchor: .bottom)
                overlay(t)
            }
            .frame(width: 92, height: 92)
        }
    }

    private func lift(_ t: Double) -> Double {
        switch mood {
        case .working: abs(sin(t * 5)) * 7
        case .happy: abs(sin(t * 7)) * 14
        default: 0
        }
    }

    private func tilt(_ t: Double) -> Double {
        switch mood {
        case .waiting: sin(t * 10) * 7
        case .idle: sin(t * 0.8) * 2
        default: 0
        }
    }

    private func breathe(_ t: Double) -> Double {
        switch mood {
        case .sleeping: 1 + sin(t * 1.4) * 0.04
        case .sad: 0.92
        default: 1 + sin(t * 2) * 0.015
        }
    }

    private func blinking(_ t: Double) -> Bool {
        t.truncatingRemainder(dividingBy: 4.2) < 0.14
    }

    @ViewBuilder
    private func figure(_ t: Double) -> some View {
        ZStack {
            // Body with little ears, loosely a blob-cat.
            Group {
                Triangle().fill(palette.1).frame(width: 18, height: 16).rotationEffect(.degrees(-18)).offset(x: -19, y: -27)
                Triangle().fill(palette.1).frame(width: 18, height: 16).rotationEffect(.degrees(18)).offset(x: 19, y: -27)
            }
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [palette.0, palette.1], startPoint: .top, endPoint: .bottom))
                .frame(width: 70, height: 62)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.5), lineWidth: 1.5)
                )
                .offset(y: 4)
            face(t).offset(y: 4)
        }
    }

    @ViewBuilder
    private func face(_ t: Double) -> some View {
        let eyeColor = Color(red: 0.16, green: 0.18, blue: 0.26)
        ZStack {
            HStack(spacing: 18) {
                eye(t, color: eyeColor, mirrored: false)
                eye(t, color: eyeColor, mirrored: true)
            }
            .offset(y: -4)
            HStack(spacing: 34) {
                Circle().fill(Color.pink.opacity(0.35)).frame(width: 10, height: 6)
                Circle().fill(Color.pink.opacity(0.35)).frame(width: 10, height: 6)
            }
            .offset(y: 6)
            mouth.stroke(eyeColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 6)
                .offset(y: 10)
        }
    }

    @ViewBuilder
    private func eye(_ t: Double, color: Color, mirrored: Bool) -> some View {
        switch mood {
        case .sleeping:
            Capsule().fill(color).frame(width: 10, height: 2.5)
        case .happy:
            Arc(up: true).stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).frame(width: 10, height: 6)
        case .sad:
            Capsule().fill(color).frame(width: 7, height: blinking(t) ? 1.5 : 8)
                .rotationEffect(.degrees(mirrored ? -20 : 20))
        case .waiting:
            Circle().fill(color).frame(width: 10, height: blinking(t) ? 1.5 : 10)
        default:
            Capsule().fill(color).frame(width: 7, height: blinking(t) ? 1.5 : 10)
        }
    }

    private var mouth: Arc {
        switch mood {
        case .sad: Arc(up: true)
        case .waiting: Arc(up: true, flat: true)
        default: Arc(up: false)
        }
    }

    @ViewBuilder
    private func overlay(_ t: Double) -> some View {
        ZStack {
            if skin == nil && mood == .sleeping {
                let phase = t.truncatingRemainder(dividingBy: 3) / 3
                Text("z")
                    .font(.system(size: 12 + phase * 6, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .opacity(1 - phase)
                    .offset(x: 30 + phase * 8, y: -26 - phase * 18)
            }
            if skin == nil && mood == .working {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .rotationEffect(.degrees(t * 180))
                    .offset(x: 32, y: -30)
            }
            if skin == nil && mood == .happy {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(.yellow)
                    .offset(x: -34, y: -30)
            }
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(.red))
                    .offset(x: 32, y: -32)
            }
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct Arc: Shape {
    var up: Bool
    var flat = false

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: up ? rect.maxY : rect.minY))
            let control = flat
                ? CGPoint(x: rect.midX, y: rect.midY)
                : CGPoint(x: rect.midX, y: up ? rect.minY - rect.height : rect.maxY + rect.height)
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: up ? rect.maxY : rect.minY), control: control)
        }
    }
}
