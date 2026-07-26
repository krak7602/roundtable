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
    @State private var numberJumps = HotkeyManager.shared.numberJumpsEnabled
    /// Bumped after a recording so the buttons redraw with the new combination.
    @State private var shortcutRevision = 0

    var body: some View {
        Form {
            Section("Sound") {
                Toggle("Play a sound on alerts", isOn: $settings.soundEnabled)
                soundPicker("Waiting", selection: $settings.waitingSound)
                soundPicker("Permission", selection: $settings.permissionSound)
            }

            // Parked, not removed: Roundtable ships as the floating orb for now.
            // The menu-bar presentation still works end to end — put this section
            // back to offer the choice again.
            //
            // Section("Where it lives") {
            //     Picker("Show Roundtable in", selection: $settings.presentation) {
            //         ForEach(Presentation.allCases) { Text($0.label).tag($0) }
            //     }
            //     .pickerStyle(.radioGroup)
            // }

            Section("Display") {
                Toggle("Show toasts on all screens", isOn: $settings.fireOnAllScreens)
                Text("Off: alerts appear on the screen you're focused on. On: on every screen, each placed for that screen's state.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Don't duplicate the terminal's own notifications", isOn: $settings.deferTerminalNotifications)
                Text("On: stay quiet for a session whose terminal already notifies you (muxy), so you aren't alerted twice. The session still appears in the list with its Allow/Deny.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.label)
                            Text(action.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShortcutRecorder(action: action, onChange: { shortcutRevision += 1 })
                            .frame(width: 116, height: 22)
                            .id("\(action.rawValue)-\(shortcutRevision)")
                    }
                }
                Toggle("Jump to a session with its number", isOn: $numberJumps)
                    .onChange(of: numberJumps) { _, on in HotkeyManager.shared.numberJumpsEnabled = on }
                Text("⌘⌥1 through ⌘⌥9 go straight to the first nine sessions in the list.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Click a shortcut and press the keys you want. Escape cancels, Delete clears it. A combination already taken by another app won't register.")
                    .font(.caption2).foregroundStyle(.tertiary)
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
