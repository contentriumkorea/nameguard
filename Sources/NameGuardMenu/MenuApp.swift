import AppKit
import Foundation
import Darwin

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let session: MenuSession
    private let queue = DispatchQueue(label: "local.nameguard.menu-worker", qos: .utility)
    private var item: NSStatusItem!
    private var timer: Timer?
    private var snapshot = MenuSnapshot(status: [:], runningPID: nil, paused: false)
    private var stopping = false
    private var terminationSignal: DispatchSourceSignal?

    init(directory: String, configPath: String, executable: String) {
        session = MenuSession(directory: directory, configPath: configPath, executable: executable)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "textformat.abc", accessibilityDescription: "NameGuard")
        item.button?.toolTip = "NameGuard · 시작 중"
        updateMenu()
        perform { try self.session.start() }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        // The status stays fresh even while an NSMenu is tracking mouse events.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func perform(_ work: @escaping () throws -> Void) {
        queue.async {
            do { try work() } catch { self.session.report(error) }
            self.publish()
        }
    }

    private func refresh() { queue.async { self.publish() } }

    private func publish() {
        let value = session.snapshot()
        DispatchQueue.main.async {
            self.snapshot = value
            self.item.button?.toolTip = "NameGuard · " + value.title
            let symbol = value.paused ? "pause.circle" :
                (["감시 중", "검사 중"].contains(value.title) ? "textformat.abc" : "exclamationmark.circle")
            self.item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NameGuard · " + value.title)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenu(menu) }

    private func updateMenu(_ existing: NSMenu? = nil) {
        let menu = existing ?? NSMenu()
        menu.delegate = self
        menu.removeAllItems()
        func label(_ title: String) { let row = menu.addItem(withTitle: title, action: nil, keyEquivalent: ""); row.isEnabled = false }
        func action(_ title: String, _ selector: Selector) {
            let row = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); row.target = self
        }
        label("NameGuard · " + snapshot.title)
        label("이번 실행 \(snapshot.renamed)건 처리 · \(snapshot.pending)건 대기")
        if !snapshot.detail.isEmpty { label(snapshot.detail) }
        menu.addItem(.separator())
        label("감시 폴더 (하위 폴더 포함)")
        if snapshot.roots.isEmpty { label("선택한 폴더 없음") }
        for path in snapshot.roots {
            let row = menu.addItem(withTitle: path, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let remove = sub.addItem(withTitle: "감시에서 제거", action: #selector(removeFolder(_:)), keyEquivalent: "")
            remove.target = self; remove.representedObject = path
            row.submenu = sub
        }
        action("폴더 추가…", #selector(addFolder))
        menu.addItem(.separator())
        action(snapshot.paused ? "감시 재개" : "일시중지", #selector(togglePause))
        action("다시 시작", #selector(restart))
        action("로그 폴더 열기", #selector(showLogs))
        menu.addItem(.separator())
        action("종료", #selector(quit))
        if existing == nil { item.menu = menu }
    }

    @objc private func addFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "감시할 폴더 선택"
        panel.prompt = "추가"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { result in
            guard result == .OK else { return }
            let paths = panel.urls.map(\.path)
            self.perform { try self.session.changeRoots(adding: paths) }
        }
    }

    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        perform { try self.session.changeRoots(removing: path) }
    }
    @objc private func togglePause() { perform { try self.session.togglePause() } }
    @objc private func restart() { perform { try self.session.restart() } }
    @objc private func showLogs() { NSWorkspace.shared.open(URL(fileURLWithPath: session.directory)) }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !stopping else { return .terminateLater }
        stopping = true
        timer?.invalidate()
        queue.async {
            self.session.stop()
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

public func runMenuApp(directory: String, configPath: String, executable: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MenuApp(directory: directory, configPath: configPath, executable: executable)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
