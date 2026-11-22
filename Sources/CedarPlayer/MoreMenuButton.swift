import SwiftUI
import AppKit

/// AppKit "More" menu: not recreated by frequent meter updates,
/// so submenus (for example, "Repeat") do not collapse on hover.
struct MoreMenuButton: View {
    @EnvironmentObject private var engine: PlayerEngine
    @Environment(\.openWindow) private var openWindow
    @AppStorage("meterStyle") private var meterStyleRaw = MeterStyle.segments.rawValue

    var onFindCover: () -> Void

    var body: some View {
        Button(action: presentMenu) {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ещё")
    }

    private var currentStyle: MeterStyle {
        MeterStyle(rawValue: meterStyleRaw) ?? .segments
    }

    private func presentMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item(L10n.string("Перемешивание"), checked: engine.isShuffle) {
            engine.isShuffle.toggle()
        })

        let repeatMenu = NSMenu()
        repeatMenu.autoenablesItems = false
        for mode in [RepeatMode.off, .all, .one] {
            repeatMenu.addItem(item(repeatTitle(mode), checked: engine.repeatMode == mode) {
                engine.repeatMode = mode
            })
        }
        menu.addItem(submenu(L10n.string("Повтор"), submenu: repeatMenu))

        menu.addItem(.separator())

        menu.addItem(item(L10n.string("Найти обложку…"), enabled: engine.currentTrack != nil) {
            onFindCover()
        })

        menu.addItem(.separator())

        menu.addItem(item(L10n.string("Выравнивать громкость (ReplayGain)"), checked: engine.isReplayGainEnabled) {
            engine.isReplayGainEnabled.toggle()
        })
        menu.addItem(item(L10n.string("Эквалайзер включён"), checked: engine.isEQEnabled) {
            engine.isEQEnabled.toggle()
        })
        menu.addItem(item(L10n.string("Открыть эквалайзер")) { openWindow(id: "equalizer") })
        menu.addItem(item(L10n.string("Текст песни")) { openWindow(id: "lyrics") })
        menu.addItem(item(L10n.string("Окно обложки")) { openWindow(id: "albumart") })
        menu.addItem(item(L10n.string("Библиотека")) { openWindow(id: "library") })
        menu.addItem(item(L10n.string("Очередь")) { openWindow(id: "queue") })

        menu.addItem(.separator())

        let meterMenu = NSMenu()
        meterMenu.autoenablesItems = false
        for style in MeterStyle.allCases {
            meterMenu.addItem(item(style.title, checked: currentStyle == style) {
                meterStyleRaw = style.rawValue
            })
        }
        menu.addItem(submenu(L10n.string("Индикатор"), submenu: meterMenu))

        let speedMenu = NSMenu()
        speedMenu.autoenablesItems = false
        for rate in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            speedMenu.addItem(item(String(format: "%.2g×", rate),
                                   checked: abs(engine.playbackRate - rate) < 0.01) {
                engine.playbackRate = rate
            })
        }
        menu.addItem(submenu(L10n.string("Скорость"), submenu: speedMenu))

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func repeatTitle(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: return L10n.string("Выключен")
        case .all: return L10n.string("Список")
        case .one: return L10n.string("Один трек")
        }
    }

    private func item(_ title: String,
                      checked: Bool = false,
                      enabled: Bool = true,
                      handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }

    private func submenu(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

/// Menu item that runs a closure and retains it until the menu closes.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    @objc private func fire() {
        handler()
    }
}
