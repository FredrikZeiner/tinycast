import SwiftUI

/// Hidden buttons sit in the capsule's rounded end, so the glass container buds them out of it.
struct CompactCommandsRow: View {
    let commands: [CommandID]
    let onRun: (CommandID) -> Void
    @Environment(PaletteState.self) private var palette
    @Environment(\.metrics) private var metrics
    @State private var isRevealed = false

    var body: some View {
        let gap = metrics.spacing.lg
        let step = metrics.size.compactHeight + gap
        HStack(spacing: gap) {
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                CompactCommandButton(command: command, isRevealed: isRevealed) { onRun(command) }
                    .offset(x: isRevealed ? 0 : -step * CGFloat(index + 1))
                    .animation(Theme.CompactBarMotion.reveal(index), value: isRevealed)
            }
        }
        // Each summon, and each return from the expanded list, replays the reveal.
        .onAppear { isRevealed = palette.isVisible }
        .onChange(of: palette.isVisible) { _, visible in isRevealed = visible }
    }
}

/// Hover state lives here, so lighting one glyph never re-renders the bar around it.
private struct CompactCommandButton: View {
    let command: CommandID
    let isRevealed: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.metrics) private var metrics

    var body: some View {
        Button(action: action) {
            Image(systemName: command.sfSymbol)
                .font(metrics.typography.headerIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                .frame(width: metrics.size.compactHeight, height: metrics.size.compactHeight)
                .background(Theme.Colors.panelScrim, in: .circle)
                // Tucked under the capsule, the scrim would darken its end twice over.
                .opacity(isRevealed ? 1 : 0)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .allowsHitTesting(isRevealed)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: Theme.Duration.hover), value: hovered)
        .help(command.name)
        .accessibilityLabel(command.name)
    }
}
