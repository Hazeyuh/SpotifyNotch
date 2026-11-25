import AppKit
import SwiftUI

/// 贴合 MacBook 物理刘海的凹耳圆角形状（参考 DynamicNotchKit / BoringNotch）
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 12) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// 刘海右翼精致 5 柱音乐律动频谱条
struct AudioWaveView: View {
    let isPlaying: Bool
    var maxHeight: CGFloat = 15

    private let weights: [CGFloat] = [0.55, 0.95, 0.72, 1.0, 0.62]
    private let speeds: [Double] = [4.1, 5.3, 3.7, 4.9, 4.4]
    private let phases: [Double] = [0.0, 1.3, 2.5, 0.8, 1.9]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { idx in
                    let amp = isPlaying
                        ? (0.24 + 0.76 * (0.5 + 0.5 * sin(t * speeds[idx] + phases[idx])))
                        : 0.18
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.18, green: 0.85, blue: 0.45), Color(red: 0.42, green: 0.98, blue: 0.72)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 2.3, height: max(3.0, maxHeight * weights[idx] * amp))
                }
            }
            .frame(height: maxHeight, alignment: .center)
        }
    }
}

/// 系统录音 / 摄像头 / 录屏呼吸状态点
struct SystemStatusDotsView: View {
    let isMicActive: Bool
    let isCameraActive: Bool
    let isScreenRecording: Bool

    var hasAny: Bool { isMicActive || isCameraActive || isScreenRecording }

    var body: some View {
        if hasAny {
            HStack(spacing: 4) {
                if isScreenRecording {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .help("正在录屏")
                }
                if isCameraActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6.5, height: 6.5)
                        .shadow(color: .green.opacity(0.8), radius: 3)
                        .help("摄像头使用中")
                }
                if isMicActive {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6.5, height: 6.5)
                        .shadow(color: .orange.opacity(0.8), radius: 3)
                        .help("麦克风录音中")
                }
            }
        }
    }
}

/// 苹果原生 macOS 26+ Liquid Glass（使用 .regular 保留完整玻璃边缘折射高光，外层不做 clipShape 裁切）
struct NativeLiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tintOpacity: Double

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    Glass.regular.tint(Color.black.opacity(tintOpacity)),
                    in: shape
                )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    func nativeLiquidGlass<S: Shape>(in shape: S, tintOpacity: Double = 0.16) -> some View {
        modifier(NativeLiquidGlassModifier(shape: shape, tintOpacity: tintOpacity))
    }
}
