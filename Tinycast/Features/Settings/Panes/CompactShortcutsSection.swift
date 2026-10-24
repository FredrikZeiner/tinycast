import SwiftUI

struct CompactShortcutsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            ForEach(settings.compactBarCommands, id: \.self) { command in
                shortcut(command)
            }
            Menu("Add Shortcut", systemImage: "plus") {
                ForEach(availableCommands, id: \.self) { command in
                    Button(command.name, systemImage: command.sfSymbol) {
                        guard settings.compactBarCommands.count < CommandID.compactBarLimit,
                            !settings.compactBarCommands.contains(command)
                        else { return }
                        settings.compactBarCommands.append(command)
                    }
                }
            }
            .disabled(settings.compactBarCommands.count >= CommandID.compactBarLimit)
        } header: {
            SettingsSectionHeader(.generalCompactShortcuts)
        }
    }

    private var availableCommands: [CommandID] {
        CommandID.compactBarOptions.filter { !settings.compactBarCommands.contains($0) }
    }

    private func shortcut(_ command: CommandID) -> some View {
        HStack {
            Picker(selection: binding(for: command)) {
                ForEach(CommandID.compactBarOptions, id: \.self) { option in
                    if option == command || !settings.compactBarCommands.contains(option) {
                        Text(option.name).tag(option)
                    }
                }
            } label: {
                Image(systemName: command.sfSymbol)
            }
            .accessibilityLabel(command.name)
            Button("Move Up", systemImage: "chevron.up") { move(command, by: -1) }
                .disabled(settings.compactBarCommands.first == command)
            Button("Move Down", systemImage: "chevron.down") { move(command, by: 1) }
                .disabled(settings.compactBarCommands.last == command)
            Button("Remove", systemImage: "minus") {
                settings.compactBarCommands.removeAll { $0 == command }
            }
        }
        .labelStyle(.iconOnly)
    }

    private func binding(for command: CommandID) -> Binding<CommandID> {
        Binding(
            get: { command },
            set: { replacement in
                guard let index = settings.compactBarCommands.firstIndex(of: command),
                    !settings.compactBarCommands.contains(replacement)
                else { return }
                settings.compactBarCommands[index] = replacement
            })
    }

    private func move(_ command: CommandID, by step: Int) {
        guard let index = settings.compactBarCommands.firstIndex(of: command) else { return }
        let destination = index + step
        guard settings.compactBarCommands.indices.contains(destination) else { return }
        settings.compactBarCommands.swapAt(index, destination)
    }
}
