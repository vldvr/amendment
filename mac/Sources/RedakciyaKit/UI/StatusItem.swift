import AppKit

/// The menu bar icon and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    var editor: ClipboardEditor?
    var onSettings: () -> Void = {}
    var onDesk: () -> Void = {}
    var onArchive: () -> Void = {}
    var desk: Desk?
    var screenshots: Screenshots?
    var gazette: GazetteStore?
    var onGazette: () -> Void = {}

    var buttonFrame: CGRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        let f = window.convertToScreen(button.convert(button.bounds, to: nil))
        return f.width > 0 ? f : nil
    }

    var buttonScreen: NSScreen? { item?.button?.window?.screen }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        let image = NSImage(systemSymbolName: "newspaper", accessibilityDescription: "Редакция")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Редакция"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    /// On pause the icon is dimmed, as macOS does for disabled items.
    func refreshIcon() {
        let paused = editor?.paused ?? false
        item?.button?.appearsDisabled = paused
        item?.button?.toolTip = paused ? "Редакция: Редактура на паузе" : "Редакция"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Prefs.shared
        let paused = editor?.paused ?? false
        if prefs.gazetteEnabled {
            let it = action(GazetteText.menu, #selector(openGazette))
            if let n = gazette?.latest?.number, n > prefs.gazetteReadNumber { it.badge = NSMenuItemBadge(string: GazetteText.unread) }
            menu.addItem(it)
            menu.addItem(.separator())
        }
        menu.addItem(disabled(paused ? "Редактура на паузе" : EditingText.silent(prefs.tailsRemoved)))
        let access = ClipboardAccess.current()
        if let warning = access.menuWarning, let fix = access.menuFix {
            menu.addItem(disabled(warning))
            menu.addItem(action(fix, #selector(openPasteSettings)))
        }

        if let editor, let last = editor.last, editor.lastIsCurrent {
            switch last.state {
            case .cleaned: menu.addItem(action("Вернуть хвост", #selector(returnTail)))
            case .returned: menu.addItem(action("Убрать хвост снова", #selector(cleanAgain)))
            }
            let app = last.event.appName
            menu.addItem(action("Не трогать ссылки из \(app)", #selector(exclude(_:)), object: last.event.appID))
        }
        let excluded = prefs.excludedApps.sorted()
        if !excluded.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabled("Не трогаю ссылки из:"))
            for id in excluded {
                let it = action(Apps.name(id), #selector(include(_:)), object: id)
                it.state = .on
                it.toolTip = "Снять исключение"
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        menu.addItem(action(paused ? "Включить Редактуру" : "Пауза Редактуры", #selector(togglePause)))

        if let screenshots, prefs.screenshotsEnabled {
            menu.addItem(.separator())
            screenshots.addMenuItems(to: menu, target: self, quitStandalone: #selector(quitZamazka), turnOn: #selector(openSettings))
        }

        menu.addItem(.separator())
        if prefs.deskPaused {
            menu.addItem(disabled("Стол на паузе"))
        } else {
            menu.addItem(disabled(DeskText.status(prefs.deskLastMoved)))
        }
        if let desk, !desk.lastSweep.isEmpty {
            menu.addItem(action("Вернуть на место", #selector(returnDesk)))
        }
        menu.addItem(action("Стол…", #selector(openDesk)))
        menu.addItem(action("Архив…", #selector(openArchive)))
        menu.addItem(action("Показать убранное", #selector(showDesk)))
        menu.addItem(action(prefs.deskPaused ? "Включить Стол" : "Пауза Стола", #selector(toggleDeskPause)))
        menu.addItem(.separator())
        menu.addItem(action("Настройки…", #selector(openSettings), key: ","))
        menu.addItem(action("Выйти", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", object: Any? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        it.target = self
        it.representedObject = object
        return it
    }

    @objc private func returnTail() { editor?.returnTail() }
    @objc private func cleanAgain() { editor?.cleanAgain() }

    @objc private func exclude(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.shared.excludedApps.insert(id)
    }

    @objc private func include(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.shared.excludedApps.remove(id)
    }

    @objc private func togglePause() {
        Prefs.shared.editingPaused.toggle()
    }

    @objc private func openSettings() { onSettings() }
    @objc private func openDesk() { onDesk() }
    @objc private func openGazette() { onGazette() }
    @objc private func openArchive() { onArchive() }
    @objc private func quitZamazka() { screenshots?.quitStandalone() }

    @objc private func returnDesk() {
        guard let desk else { return }
        desk.returnLastSweep()
        Prefs.shared.deskLastMoved = 0
    }

    @objc private func showDesk() {
        let url = desk?.destination ?? Desk.defaultDestination
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleDeskPause() { Prefs.shared.deskPaused.toggle() }
    @objc private func openPasteSettings() { ClipboardAccess.openSystemSettings() }

    @objc private func quit() { NSApp.terminate(nil) }
}
