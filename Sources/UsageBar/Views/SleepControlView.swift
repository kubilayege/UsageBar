import SwiftUI

/// Disable Sleep as a switch: the control says what it does, the switch says its state.
struct SleepControlView: View {
    @ObservedObject private var control = SleepControl.shared
    var showsError = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: control.isSleepDisabled == true ? "cup.and.saucer.fill" : "moon.zzz")
                    .font(.system(size: 11.5))
                    .foregroundStyle(control.isSleepDisabled == true ? Theme.accent : Theme.textMuted)
                    .frame(width: 14)
                Text("Disable sleep").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                if control.isChanging {
                    ProgressView().controlSize(.mini)
                } else if control.isSleepDisabled == nil {
                    Text("unknown").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                Toggle("Disable sleep", isOn: Binding(
                    get: { control.isSleepDisabled == true },
                    set: { _ in Task { await control.toggle() } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(Theme.accent)
                    .disabled(control.isChanging)
            }
            .help(control.isPasswordless
                  ? "Runs pmset -b disablesleep 1 or 0 through UsageBar's passwordless sudo rule. macOS reports this as a system-wide setting; it persists after UsageBar quits."
                  : "Runs pmset -b disablesleep 1 or 0 with macOS administrator approval. Settings can make this passwordless. macOS reports this as a system-wide setting; it persists after UsageBar quits.")
            if showsError, let error = control.errorMessage {
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
        SettingsRow("Change sleep without a password",
                    detail: control.isPasswordless
                        ? "Sleep access is enabled for your account. Confirmation applies to UsageBar; other apps running as your account can also change sleep. Turn this off to remove access."
                        : "Approve administrator access once, then confirm sleep changes with Touch ID or your login password. This also lets other apps running as your account change sleep without administrator approval.") {
            Toggle("", isOn: Binding(
                get: { control.isPasswordless },
                set: { enabled in Task { await control.setPasswordless(enabled) } }))
                .disabled(control.isChanging)
        }
        if control.isPasswordless {
            SettingsRow("Confirm with Touch ID or password") {
                Toggle("", isOn: $settings.confirmSleepWithTouchID).disabled(control.isChanging)
            }
        }
    }
}
