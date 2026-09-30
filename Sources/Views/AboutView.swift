import SwiftUI

/// About panel, family style with BPMPLS's AboutView: glyph, name, version,
/// SKSoft credit, MIT note — plus the BPMPLS engine credit line.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 38))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 2)
            Text("MKDJ").font(.title2).bold()
            Text(Self.version).font(.caption).foregroundStyle(.secondary)
            Text("LLM development by SKSoft.")
                .font(.callout)
            Text("Licensed under the MIT License")
                .font(.caption).foregroundStyle(.secondary)
            Text("BPM engine from BPMPLS")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(24)
        .frame(width: 340)
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
