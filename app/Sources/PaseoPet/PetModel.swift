import AppKit
import Combine

enum PetMood {
    case sleeping, idle, working, waiting, happy, sad
}

struct InfoBubble: Identifiable, Equatable {
    enum Kind { case completed, failed, system }

    let id = UUID()
    let kind: Kind
    let agent: PetAgent?
    let text: String
}

struct PermissionBubble: Equatable {
    let agent: PetAgent
    let permission: PetPermission
}

@MainActor
final class PetModel: ObservableObject {
    static let paseoBundleId = "sh.paseo.desktop"

    @Published private(set) var agents: [PetAgent] = []
    @Published private(set) var connected = false
    @Published private(set) var paseoActive = false
    @Published private(set) var info: InfoBubble?
    @Published private(set) var flash: PetMood?
    @Published var busyRequestId: String?
    @Published var lastError: String?

    @Published var hideWhilePaseoActive: Bool {
        didSet { UserDefaults.standard.set(hideWhilePaseoActive, forKey: "hideWhilePaseoActive") }
    }
    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    /// Folder name under Skins, or nil for the built-in character.
    @Published var skinName: String? {
        didSet {
            UserDefaults.standard.set(skinName, forKey: "skin")
            reloadSkin()
        }
    }
    @Published private(set) var skin: Skin?

    let bridge = BridgeClient()
    private var queue: [InfoBubble] = []
    private var dismissTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var dismissedRequests = Set<String>()

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["hideWhilePaseoActive": true, "soundEnabled": true])
        hideWhilePaseoActive = defaults.bool(forKey: "hideWhilePaseoActive")
        soundEnabled = defaults.bool(forKey: "soundEnabled")
        skinName = defaults.string(forKey: "skin")
        reloadSkin()
        paseoActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.paseoBundleId

        bridge.onSnapshot = { [weak self] agents in self?.agents = agents }
        bridge.onNotice = { [weak self] notice in self?.handle(notice) }
        bridge.onConnectionChange = { [weak self] connected in self?.connected = connected }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.paseoActive = app?.bundleIdentifier == Self.paseoBundleId
            }
        }
        bridge.start()
    }

    func reloadSkin() {
        skin = skinName.flatMap(Skin.load)
    }

    // MARK: Derived state

    /// The user is already looking at Paseo, so the pet stays out of the way.
    var quiet: Bool { hideWhilePaseoActive && paseoActive }

    var pendingCount: Int { agents.reduce(0) { $0 + $1.pending.count } }

    var permission: PermissionBubble? {
        for agent in agents {
            if let request = agent.pending.first(where: { !dismissedRequests.contains($0.requestId) }) {
                return PermissionBubble(agent: agent, permission: request)
            }
        }
        return nil
    }

    var mood: PetMood {
        if !connected { return .sleeping }
        if let flash { return flash }
        if pendingCount > 0 { return .waiting }
        if agents.contains(where: { $0.status == "running" }) { return .working }
        if agents.contains(where: { $0.status == "error" }) { return .sad }
        return .idle
    }

    var statusLine: String {
        if !connected { return "Paseo 브리지 대기 중" }
        let running = agents.filter { $0.status == "running" }.count
        if pendingCount > 0 { return "승인 대기 \(pendingCount)건" }
        if running > 0 { return "에이전트 \(running)개 작업 중" }
        return "모든 에이전트 쉬는 중"
    }

    // MARK: Events

    private func handle(_ notice: PetNotice) {
        switch notice.type {
        case "turn_completed":
            setFlash(.happy)
            let summary = notice.summary?.isEmpty == false ? notice.summary! : "작업을 마쳤어요."
            enqueue(InfoBubble(kind: .completed, agent: notice.agent, text: summary), sound: "Glass")
        case "turn_failed":
            setFlash(.sad)
            enqueue(InfoBubble(kind: .failed, agent: notice.agent, text: notice.message ?? "작업이 실패했어요."), sound: "Basso")
        case "permission_requested":
            if !quiet { play("Funk") }
        default:
            break
        }
    }

    private func enqueue(_ bubble: InfoBubble, sound: String) {
        // Paseo is in front; the user sees the result there.
        guard !quiet else { return }
        play(sound)
        if info == nil {
            show(bubble)
        } else {
            queue.append(bubble)
        }
    }

    private func show(_ bubble: InfoBubble) {
        info = bubble
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissInfo()
        }
    }

    func dismissInfo() {
        dismissTask?.cancel()
        info = nil
        if !queue.isEmpty {
            show(queue.removeFirst())
        }
    }

    func postSystemMessage(_ text: String) {
        show(InfoBubble(kind: .system, agent: nil, text: text))
    }

    private func setFlash(_ mood: PetMood) {
        flash = mood
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    private func play(_ name: String) {
        guard soundEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: Actions

    func respond(_ bubble: PermissionBubble, allow: Bool) {
        busyRequestId = bubble.permission.requestId
        Task {
            do {
                try await bridge.respond(agentId: bubble.agent.id, requestId: bubble.permission.requestId, allow: allow)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            busyRequestId = nil
        }
    }

    func later(_ bubble: PermissionBubble) {
        dismissedRequests.insert(bubble.permission.requestId)
        objectWillChange.send()
    }

    func open(agent: PetAgent?) {
        if let agent, let serverId = bridge.connection?.serverId,
           let url = URL(string: "paseo://h/\(serverId)/agent/\(agent.id)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.paseoBundleId) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func sendTest() {
        Task {
            do {
                try await bridge.sendTest()
            } catch {
                postSystemMessage("브리지 연결 실패: \(error.localizedDescription)")
            }
        }
    }
}
