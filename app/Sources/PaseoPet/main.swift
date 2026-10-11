import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: PetModel!
    private var window: PetWindowController!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = PetModel()
        window = PetWindowController(model: model)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusTitle()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
    }

    private func updateStatusTitle() {
        let pending = model.pendingCount
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Paseo Pet")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = pending > 0 ? " \(pending)" : ""
        statusItem.button?.appearsDisabled = !model.connected
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        for agent in model.agents.prefix(8) {
            let symbol = switch agent.status {
            case "running": "⏳"
            case "waiting": "✋"
            case "error": "⚠️"
            default: "💤"
            }
            let item = NSMenuItem(title: "\(symbol) \(agent.title)", action: #selector(openAgent(_:)), keyEquivalent: "")
            item.representedObject = agent.id
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(toggle("펫 보이기", window.visible, #selector(toggleVisible)))
        menu.addItem(toggle("Paseo 사용 중에는 숨기기", model.hideWhilePaseoActive, #selector(toggleQuiet)))
        menu.addItem(toggle("알림 소리", model.soundEnabled, #selector(toggleSound)))
        menu.addItem(skinMenu())
        menu.addItem(.separator())
        menu.addItem(action("연결 테스트", #selector(sendTest)))
        menu.addItem(action("펫 위치 초기화", #selector(resetPosition)))
        menu.addItem(action("Paseo 열기", #selector(openPaseo)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func skinMenu() -> NSMenuItem {
        let submenu = NSMenu()
        let builtIn = toggle("기본 캐릭터", model.skinName == nil, #selector(selectSkin(_:)))
        submenu.addItem(builtIn)
        for name in Skin.available() {
            let item = toggle(name, model.skinName == name, #selector(selectSkin(_:)))
            item.representedObject = name
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(action("Codex Pet 가져오기…", #selector(importCodexPet)))
        submenu.addItem(action("스킨 폴더 열기", #selector(openSkinFolder)))
        submenu.addItem(action("스킨 다시 불러오기", #selector(reloadSkin)))
        let item = NSMenuItem(title: "스킨", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ selector: Selector) -> NSMenuItem {
        let item = action(title, selector)
        item.state = on ? .on : .off
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleVisible() { window.visible.toggle() }
    @objc private func toggleQuiet() { model.hideWhilePaseoActive.toggle() }
    @objc private func toggleSound() { model.soundEnabled.toggle() }
    @objc private func sendTest() { model.sendTest() }
    @objc private func resetPosition() { window.resetPosition() }
    @objc private func selectSkin(_ sender: NSMenuItem) { model.skinName = sender.representedObject as? String }
    @objc private func reloadSkin() { model.reloadSkin() }

    @objc private func importCodexPet() {
        let alert = NSAlert()
        alert.messageText = "Codex Pet 가져오기"
        alert.informativeText = "codex-pets.net 펫 페이지 주소(예: https://codex-pets.net/#/pets/uu-usagi)나 펫 ID를 붙여 넣으세요."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://codex-pets.net/#/pets/…"
        alert.accessoryView = field
        alert.addButton(withTitle: "가져오기")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue
        Task {
            do {
                let id = try await CodexPet.install(from: input)
                model.skinName = id
                model.postSystemMessage("\(id) 펫을 적용했어요.")
            } catch {
                model.postSystemMessage("가져오기 실패: \(error.localizedDescription)")
            }
        }
    }
    @objc private func openSkinFolder() {
        _ = Skin.available()
        NSWorkspace.shared.open(Skin.directory)
    }
    @objc private func openPaseo() { model.open(agent: nil) }

    @objc private func openAgent(_ sender: NSMenuItem) {
        let agent = model.agents.first { $0.id == sender.representedObject as? String }
        model.open(agent: agent)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
