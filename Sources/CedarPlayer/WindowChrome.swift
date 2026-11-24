import SwiftUI
import AppKit

/// A draggable strip that moves the NSWindow with the mouse.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            // AppKit exposes the drag entry point to Objective-C only.
            _ = window?.perform(Selector(("performWindowDragWithEvent:")), with: event)
        }
    }
}

/// Custom dark title bar: app mark on the left, window controls on the right.
struct WindowTitleBar: View {
    let window: NSWindow?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.Cyber.accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: Theme.Cyber.accent.opacity(0.9), radius: 5)
                Text("CEDAR PLAYER")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Theme.Cyber.secondaryText)
            }

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                WindowControlButton(symbol: "minus", help: "Свернуть") {
                    window?.miniaturize(nil)
                }
                WindowControlButton(symbol: "square", help: "Развернуть / восстановить") {
                    window?.zoom(nil)
                }
                WindowControlButton(symbol: "xmark", help: "Закрыть", danger: true) {
                    window?.performClose(nil)
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Theme.Layout.titleBarHeight)
        .background {
            ZStack {
                Theme.Cyber.titleBar
                LinearGradient(colors: [Color.white.opacity(0.035), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Cyber.separator.opacity(0.8)).frame(height: 1)
        }
        .background(WindowDragArea())
        .accessibilityElement(children: .contain)
    }
}

private struct WindowControlButton: View {
    let symbol: String
    let help: String
    var danger = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovered ? (danger ? Color.white : Theme.Cyber.accentBright) : Theme.Cyber.secondaryText)
                .frame(width: 22, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovered ? (danger ? Theme.Cyber.danger : Theme.Cyber.hover) : Theme.Cyber.subtle.opacity(0.45))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovered ? 0.18 : 0.06), lineWidth: 0.7)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
