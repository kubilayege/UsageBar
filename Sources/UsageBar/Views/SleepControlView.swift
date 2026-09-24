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
                .help(control.isPasswordless
                      ? "Runs pmset -b disablesleep 1 or 0 through UsageBar's passwordless sudo rule. macOS reports this as a system-wide setting; it persists after UsageBar quits."
                      : "Runs pmset -b disablesleep 1 or 0 with macOS administrator approval. Settings can make this passwordless. macOS reports this as a system-wide setting; it persists after UsageBar quits.")
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

/// Settings rows for authorizing sleep access once, with optional local authentication for later changes.
struct SleepAccessRows: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var control = SleepControl.shared

    var body: some View {
        Toggle("Change sleep without a password", isOn: Binding(
            get: { control.isPasswordless },
            set: { enabled in Task { await control.setPasswordless(enabled) } }))
            .disabled(control.isChanging)
        if control.isPasswordless {
            Toggle("Confirm with Touch ID or password", isOn: $settings.confirmSleepWithTouchID)
                .disabled(control.isChanging)
        }
        Text(control.isPasswordless
             ? "Sleep access is enabled for your account. Confirmation applies to UsageBar; other apps running as your account can also change sleep. Turn this off to remove access."
             : "Approve administrator access once, then confirm sleep changes with Touch ID or your login password. This also lets other apps running as your account change sleep without administrator approval.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
