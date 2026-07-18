import SwiftUI
import AppKit

/// The Settings panel: sound preferences, which harnesses to show, and one-click
/// "enhanced detection" (installs the harness's hook/extension so Roundtable can
/// catch permission prompts that transcript-tailing can't see).
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var claudeHook = HookInstaller.isInstalled()
    @State private var codexHook = CodexHookInstaller.isInstalled()
    @State private var ompHook = OmpHookInstaller.isInstalled()
    @State private var hookNote = ""

    var body: some View {
        Form {
            Section("Sound") {
                Toggle("Play a sound on alerts", isOn: $settings.soundEnabled)
                soundPicker("Waiting", selection: $settings.waitingSound)
                soundPicker("Permission", selection: $settings.permissionSound)
            }

            Section("Display") {
                Toggle("Show toasts on all screens", isOn: $settings.fireOnAllScreens)
                Text("Off: shows on the screen you're focused on — a floating pill over full-screen apps, or the menu-bar item otherwise. On: a pill on every screen, each placed for that screen's state.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Show harnesses") {
                ForEach(Harness.allCases, id: \.self) { h in
                    Toggle(h.rawValue, isOn: Binding(
                        get: { settings.isEnabled(h) },
                        set: { settings.setEnabled(h, $0) }))
                }
            }

            Section("Enhanced detection") {
                Toggle("Claude Code — catch permission prompts", isOn: $claudeHook)
                    .onChange(of: claudeHook) { _, on in
                        hookNote = on
                            ? HookInstaller.install(binaryPath: HookInstaller.executablePath)
                            : HookInstaller.uninstall()
                        reconcile(&claudeHook, HookInstaller.isInstalled())
                    }
                Text("Adds Notification + Stop hooks to your Claude settings (backed up first). Without this, permission prompts in Claude aren't detected.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Codex — catch permission prompts", isOn: $codexHook)
                    .onChange(of: codexHook) { _, on in
                        hookNote = on
                            ? CodexHookInstaller.install(binaryPath: HookInstaller.executablePath)
                            : CodexHookInstaller.uninstall()
                        reconcile(&codexHook, CodexHookInstaller.isInstalled())
                    }
                Text("Adds a PermissionRequest hook to ~/.codex/config.toml (backed up first). Needs a recent Codex (rust-v0.14x+).")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Oh My Pi — catch permission prompts", isOn: $ompHook)
                    .onChange(of: ompHook) { _, on in
                        hookNote = on
                            ? OmpHookInstaller.install(binaryPath: HookInstaller.executablePath)
                            : OmpHookInstaller.uninstall()
                        reconcile(&ompHook, OmpHookInstaller.isInstalled())
                    }
                Text("Drops a hook at ~/.omp/agent/hooks/pre/ that relays omp's approval prompts. Loads automatically for every omp session.")
                    .font(.caption).foregroundStyle(.secondary)

                if !hookNote.isEmpty {
                    Text(hookNote).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 600)
    }

    /// Snap a toggle back to what actually happened on disk, so a failed
    /// install/uninstall doesn't leave the switch lying about its state.
    private func reconcile(_ binding: inout Bool, _ actual: Bool) {
        if binding != actual { binding = actual }
    }

    private func soundPicker(_ label: String, selection: Binding<String>) -> some View {
        HStack {
            Picker(label, selection: selection) {
                ForEach(AppSettings.availableSounds, id: \.self) { Text($0).tag($0) }
            }
            Button {
                NSSound(named: selection.wrappedValue)?.play()
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Preview")
        }
    }
}
