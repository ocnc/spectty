import SwiftUI

/// An audio-level visualization, not a transcription or speech-detection signal.
struct VoiceWaveform: View {
    let level: Double
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || level < 0.01)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: .pi * 5) * 4
            let wave = VoiceWave(level: level, phase: phase)
            ZStack {
                wave.stroke(color.opacity(0.15), lineWidth: 8)
                    .blur(radius: 6)
                wave.stroke(
                    LinearGradient(colors: [color.opacity(0.15), color, color.opacity(0.15)], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .opacity(0.35 + level * 0.65)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: level)
        }
        .frame(maxWidth: 260)
        .frame(height: 72)
        .accessibilityHidden(true)
    }
}

struct VoiceWave: Shape {
    var level: Double
    let phase: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path { path in
            for step in 0...80 {
                let x = Double(step) / 80
                let envelope = pow(sin(.pi * x), 2)
                let oscillation = (sin(x * .pi * 3 - phase) + 0.35 * sin(x * .pi * 6 + phase * 0.6)) / 1.35
                let amplitude = min(1, max(0, level)) * rect.height * 0.38
                let point = CGPoint(x: rect.minX + rect.width * x, y: rect.midY + oscillation * envelope * amplitude)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
