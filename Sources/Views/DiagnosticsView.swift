import SwiftUI
import AppKit

/// Live tail of the app log + beep-suppression counter, so key / beep
/// forensics don't need a terminal. Window ▸ Diagnostics.
struct DiagnosticsView: View {
    @State private var lines: [String] = []
    @State private var beeps = 0
    @ObservedObject private var frames = FrameStats.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Beeps suppressed: \(beeps)")
                    .foregroundColor(beeps == 0 ? Theme.muted : Theme.amber)
                    .font(Theme.mono)
                // the p95>8ms amber warning was unreachable — a second
                // .foregroundColor on the same Text always won
                Text(String(format: "Lane draw: p50 %.2f · p95 %.2f · max %.2f ms (%d frames)",
                            frames.p50ms, frames.p95ms, frames.maxMs, frames.frames))
                    .foregroundColor(frames.p95ms > 8 ? Theme.amber : Theme.muted)
                    .font(Theme.mono)
                Spacer()
                Button("Reveal Log") {
                    NSWorkspace.shared.selectFile(MKLog.logURL.path, inFileViewerRootedAtPath: "")
                }
                Button("Clear View") { lines = []; _ = MKLog.shared.recent }
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .default))
                            .foregroundColor(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { refresh() }
        .background(
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                Color.clear.onAppear { refresh() }
            }
        )
    }

    private func refresh() {
        lines = MKLog.shared.recent
        beeps = BeepGuard.suppressedCount
    }

    private func color(for line: String) -> Color {
        if line.contains("[beep]") { return Theme.amber }
        if line.contains("[ERROR]") { return Theme.playheadRed }
        if line.contains("[keys]") { return Theme.muted }
        return Theme.ink.opacity(0.8)
    }
}
