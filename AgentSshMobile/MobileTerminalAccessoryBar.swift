import SwiftUI

struct MobileTerminalAccessoryBar: View {
    @EnvironmentObject private var terminalPreferences: MobileTerminalPreferences

    let connectionId: String

    @State private var controlLatched = false
    @State private var altLatched = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                latchButton("Ctrl", isActive: controlLatched) {
                    controlLatched.toggle()
                }
                latchButton("Alt", isActive: altLatched) {
                    altLatched.toggle()
                }

                Divider()
                    .frame(height: 24)

                ForEach(MobileTerminalAccessoryKeyDefinition.selected(ids: terminalPreferences.accessoryKeyIds)) { definition in
                    keyButton(definition.title) { send(definition.key) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .background(themeBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(themeForeground.opacity(0.14))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var themeBackground: Color {
        Color(uiColor: terminalPreferences.theme.background)
    }

    private var themeForeground: Color {
        Color(uiColor: terminalPreferences.theme.foreground)
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(themeForeground)
                .frame(minWidth: title.count > 1 ? 44 : 32, minHeight: 30)
                .background(themeForeground.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ systemName: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .foregroundStyle(themeForeground)
                .frame(width: 32, height: 30)
                .background(themeForeground.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func latchButton(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(isActive ? .black : themeForeground)
                .frame(minWidth: 44, minHeight: 30)
                .background(
                    isActive ? Color.green : themeForeground.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) modifier")
        .accessibilityValue(isActive ? "On" : "Off")
    }

    private func send(_ key: MobileTerminalAccessoryKey) {
        let data = key.data(control: controlLatched, alt: altLatched)
        MobileTerminalBridge.shared.sendInput(connectionId: connectionId, data: data)

        if controlLatched {
            controlLatched = false
        }
        if altLatched {
            altLatched = false
        }
    }
}
