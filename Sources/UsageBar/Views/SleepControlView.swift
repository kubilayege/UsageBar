import SwiftUI

struct SleepControlView: View {
    @ObservedObject private var control = SleepControl.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { Task { await control.toggle() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "power")
                        Text("Disable Sleep")
                        Text(control.stateLabel).fontWeight(.bold).monospacedDigit()
                            .foregroundStyle(control.isSleepDisabled == true ? Theme.ok : Theme.textMuted)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(control.isChanging)
                .help("Runs pmset -b disablesleep 1 or 0 with macOS administrator approval. macOS reports this as a system-wide setting; it persists after UsageBar quits.")
                Spacer(minLength: 4)
                Button { Task { await control.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(control.isChanging)
                .help("Read the current macOS sleep setting")
            }
            if let error = control.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if !RenderFlags.isRendering { await control.refresh() } }
    }
}
