import AppKit
import Foundation
import Darwin

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let session: MenuSession
    private let login: LoginStartup
    private let updater: UpdateService?
    private var loginEnabled = false
    private var updating = false
    private let queue = DispatchQueue(label: "local.nameguard.menu-worker", qos: .utility)
    private var item: NSStatusItem!
    private var timer: Timer?
    private var snapshot = MenuSnapshot(status: [:], runningPID: nil, paused: false)
    private var stopping = false
    private var terminationSignal: DispatchSourceSignal?

    init(directory: String, configPath: String, executable: String) {
        session = MenuSession(directory: directory, configPath: configPath, executable: executable)
        login = LoginStartup(executable: executable, directory: directory)
        updater = AppLocation.bundle(executable: executable).map { UpdateService(directory: directory, bundle: $0) }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "textformat.abc", accessibilityDescription: "NameGuard")
        item.button?.toolTip = "NameGuard · 시작 중"
        updateMenu()
        perform {
            do { try self.session.start() }
            catch let error as NSError where error.domain == "NameGuard" && error.code == 3 {
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            do { try self.login.ensureRegistered() } catch { self.session.report(error) }
            self.queue.asyncAfter(deadline: .now() + 2) { self.acknowledgeUpdate() }
        }
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
        let enabled = login.isEnabled
        DispatchQueue.main.async {
            self.snapshot = value
            self.loginEnabled = enabled
            self.item.button?.toolTip = "NameGuard · " + value.title
            let symbol = value.paused ? "pause.circle" :
                (["감시 중", "검사 중"].contains(value.title) ? "textformat.abc" : "exclamationmark.circle")
            self.item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NameGuard · " + value.title)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenu(menu) }

    private func updateMenu(_ existing: NSMenu? = nil) {
        let menu = existing ?? NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.removeAllItems()
        func label(_ title: String) { let row = menu.addItem(withTitle: title, action: nil, keyEquivalent: ""); row.isEnabled = false }
        func action(_ title: String, _ selector: Selector) {
            let row = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); row.target = self
        }
        label("NameGuard \(updater?.version ?? "1.2.0") · " + snapshot.title)
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
        let startup = menu.addItem(withTitle: "로그인 시 자동 실행", action: #selector(toggleStartup), keyEquivalent: "")
        startup.target = self; startup.state = loginEnabled ? .on : .off
        action("로그인 항목 설정 열기", #selector(showLoginSettings))
        let update = menu.addItem(withTitle: updating ? "업데이트 처리 중…" : "업데이트 확인…", action: #selector(checkUpdate), keyEquivalent: "")
        update.target = self; update.isEnabled = !updating && updater != nil
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
    @objc private func toggleStartup() {
        let enabled = !loginEnabled
        perform { try self.login.setEnabled(enabled) }
    }
    @objc private func showLoginSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
    private func alert(_ text: String, detail: String = "", buttons: [String] = ["확인"]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = text; alert.informativeText = detail
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal()
    }
    @objc private func checkUpdate() {
        guard !updating, let updater else { return }
        updating = true
        Task {
            do {
                guard let release = try await updater.check() else {
                    await MainActor.run { _ = self.alert("최신 버전입니다.", detail: "현재 버전: \(updater.version)"); self.updating = false }
                    return
                }
                let accepted = await MainActor.run { self.alert("NameGuard \(release.version)", detail: "새 버전을 다운로드할 수 있습니다. 감시 폴더와 설정은 유지됩니다.", buttons: ["다운로드", "취소"]) == .alertFirstButtonReturn }
                guard accepted else { await MainActor.run { self.updating = false }; return }
                let staged = try await updater.prepare(release)
                let install = await MainActor.run { self.alert("다운로드 완료", detail: "재시작하면 업데이트를 설치합니다. 실행에 실패하면 기존 앱으로 복구합니다.", buttons: ["재시작·설치", "취소"]) == .alertFirstButtonReturn }
                if install {
                    try updater.install(staged, version: release.version)
                    await MainActor.run { NSApp.terminate(nil) }
                } else {
                    try? FileManager.default.removeItem(at: staged.candidate)
                    try? FileManager.default.removeItem(at: staged.workspace)
                }
            } catch {
                await MainActor.run { _ = self.alert("업데이트하지 못했습니다.", detail: error.localizedDescription) }
            }
            await MainActor.run { self.updating = false }
        }
    }
    private func acknowledgeUpdate() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--update-health"), index + 1 < arguments.count,
              let versionIndex = arguments.firstIndex(of: "--update-version"), versionIndex + 1 < arguments.count,
              let updater, arguments[versionIndex + 1] == updater.version else { return }
        let url = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let base = URL(fileURLWithPath: session.directory).appendingPathComponent("updates").standardizedFileURL
        guard url.lastPathComponent == "health", url.deletingLastPathComponent().deletingLastPathComponent().path == base.path,
              UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil,
              session.healthy else { fputs("NameGuard update: health receipt rejected\n", stderr); return }
        try? Data(updater.version.utf8).write(to: url, options: .atomic)
    }
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
