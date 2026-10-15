import Foundation
import IOKit.pwr_mgt

/// Only fresh, live lifecycle metadata can justify preventing idle sleep.
/// Callers must pass the in-memory model's summaries, never restored library cards.
enum KeepAwakePolicy {
    static let maximumEventAge = CompanionModel.staleAfter

    static func eligibleSessionIDs(enabled: Bool, isPreview: Bool, liveChats: [ChatSummary],
                                   blockedSessionIDs: Set<String> = [], now: Date = Date()) -> Set<String> {
        guard enabled, !isPreview, now.timeIntervalSince1970.isFinite else { return [] }
        return Set(liveChats.compactMap { chat in
            guard [.working, .coding, .checking].contains(chat.state),
                  !blockedSessionIDs.contains(chat.id), !chat.id.isEmpty,
                  let turnID = chat.turnID, !turnID.isEmpty,
                  let startedAt = chat.startedAt, chat.endedAt == nil,
                  startedAt.timeIntervalSince1970.isFinite,
                  chat.updatedAt.timeIntervalSince1970.isFinite,
                  startedAt <= chat.updatedAt, startedAt <= now else { return nil }
            let age = now.timeIntervalSince(chat.updatedAt)
            guard age >= 0, age < maximumEventAge else { return nil }
            return chat.id
        })
    }
}

struct KeepAwakeNativeError: Error, Equatable {
    let code: Int32

    var message: String {
        "IOKit: " + String(format: "0x%08x", UInt32(bitPattern: code))
    }
}

/// A narrow injectable boundary. No commands, settings changes, or helpers.
protocol KeepAwakeAssertionClient: AnyObject {
    func create(timeout: TimeInterval) -> Result<UInt32, KeepAwakeNativeError>
    func release(_ assertionID: UInt32) -> Int32
}

final class NativeKeepAwakeAssertionClient: KeepAwakeAssertionClient {
    func create(timeout: TimeInterval) -> Result<UInt32, KeepAwakeNativeError> {
        guard timeout.isFinite, timeout > 0, timeout <= KeepAwakeController.leaseDuration else {
            return .failure(KeepAwakeNativeError(code: kIOReturnBadArgument))
        }
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            "Codex Notch: active turns" as CFString,
            "Fresh local Codex turns are running. Display sleep is allowed." as CFString,
            nil, nil, timeout, kIOPMAssertionTimeoutActionRelease as CFString, &identifier)
        guard result == kIOReturnSuccess, identifier != 0 else {
            return .failure(KeepAwakeNativeError(code: result == kIOReturnSuccess ? kIOReturnError : result))
        }
        return .success(identifier)
    }

    func release(_ assertionID: UInt32) -> Int32 {
        IOPMAssertionRelease(assertionID)
    }
}

/// A renewable, OS-expiring idle-sleep assertion; use from the app's serial refresh loop.
/// The display can sleep or lock. Public IOKit assertions cannot override lid close,
/// explicit Apple-menu Sleep, low battery, or managed power policies.
final class KeepAwakeController {
    enum Status: String { case off, preview, waiting, active, failed }

    static let leaseDuration: TimeInterval = 120
    static let renewalInterval: TimeInterval = 60
    static let retryInterval: TimeInterval = 30

    private struct Lease {
        let id: UInt32
        let createdUptime: TimeInterval
    }

    private let client: KeepAwakeAssertionClient
    private var lease: Lease?
    private var retryAfterUptime: TimeInterval?
    private(set) var status: Status = .off
    private(set) var activeChatCount = 0
    private(set) var lastError: String?
    var assertionID: UInt32? { lease?.id }

    init(client: KeepAwakeAssertionClient = NativeKeepAwakeAssertionClient()) {
        self.client = client
    }

    deinit {
        if let lease { _ = client.release(lease.id) }
    }

    var statusText: String {
        switch status {
        case .off: return "Обычный режим сна"
        case .preview: return "Демо: режим сна не меняется"
        case .waiting: return "Включено · ждём активный ход"
        case .active: return "Mac не уснёт от бездействия · чатов: \(activeChatCount)"
        case .failed: return "Не удалось отложить сон Mac"
        }
    }

    /// `uptime` controls lease renewal independently of wall-clock adjustments.
    /// A stalled app cannot extend the lease: macOS releases it after 120 seconds.
    func update(enabled: Bool, isPreview: Bool, liveChats: [ChatSummary],
                blockedSessionIDs: Set<String> = [], now: Date = Date(),
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let eligible = KeepAwakePolicy.eligibleSessionIDs(enabled: enabled, isPreview: isPreview,
            liveChats: liveChats, blockedSessionIDs: blockedSessionIDs, now: now)
        activeChatCount = eligible.count
        guard enabled, !isPreview, !eligible.isEmpty else {
            releaseCurrent()
            retryAfterUptime = nil
            status = !enabled ? .off : isPreview ? .preview : .waiting
            return
        }
        guard uptime.isFinite, uptime >= 0 else {
            releaseCurrent()
            lastError = "Недоступно монотонное время для безопасного продления"
            status = .failed
            return
        }
        if let lease {
            let age = uptime - lease.createdUptime
            if age >= 0, age < Self.renewalInterval {
                status = .active
                return
            }
            // TimeoutActionRelease already disposed of an expired lease. Do not
            // report the expected invalid-ID response as a new release failure.
            if age >= Self.leaseDuration { self.lease = nil }
        } else if let retryAfterUptime, uptime < retryAfterUptime {
            status = .failed
            return
        }

        // Create the replacement before releasing the previous lease, avoiding a
        // sleep gap. Even a failed release is bounded by the native timeout.
        switch client.create(timeout: Self.leaseDuration) {
        case .success(let id):
            lastError = nil
            releaseCurrent()
            lease = Lease(id: id, createdUptime: uptime)
            retryAfterUptime = nil
            status = .active
            // Retain a release error for diagnostics if the old lease failed to release.
        case .failure(let error):
            releaseCurrent()
            lastError = error.message
            retryAfterUptime = uptime + Self.retryInterval
            status = .failed
        }
    }

    /// Explicit app-termination cleanup, also safe to call more than once.
    func stop() {
        releaseCurrent()
        activeChatCount = 0
        retryAfterUptime = nil
        status = .off
    }

    private func releaseCurrent() {
        guard let current = lease else { return }
        lease = nil
        let result = client.release(current.id)
        lastError = result == kIOReturnSuccess ? nil : KeepAwakeNativeError(code: result).message
    }
}

/// A viewed question is still a pause. Only a real resume/clear/lifecycle can lift it.
struct KeepAwakeQuestions {
    private struct Pause { let turnID: String; let date: Date }
    private var pauses: [String: Pause] = [:]
    var blockedSessionIDs: Set<String> { Set(pauses.keys) }

    mutating func receive(_ event: CompanionEvent, current: ChatSummary?, attentionAccepted: Bool, lifecycleAccepted: Bool) {
        if attentionAccepted, event.event == "AttentionQuestion", let turn = event.turnID {
            pauses[event.sessionID] = Pause(turnID: turn, date: event.timestamp)
            if pauses.count > 512, let oldest = pauses.min(by: { $0.value.date < $1.value.date })?.key { pauses.removeValue(forKey: oldest) }
            return
        }
        guard let pause = pauses[event.sessionID], event.timestamp >= pause.date else { return }
        if event.event == "AttentionClear", let current, current.id == event.sessionID,
           current.turnID == event.turnID, event.turnID == pause.turnID, event.timestamp >= current.updatedAt {
            pauses.removeValue(forKey: event.sessionID)
        } else if lifecycleAccepted {
            switch event.event {
            case "UserPromptSubmit": pauses.removeValue(forKey: event.sessionID)
            case "Stop", "Interrupt", "SessionEnd":
                if event.turnID == nil || event.turnID == pause.turnID { pauses.removeValue(forKey: event.sessionID) }
            default: break
            }
        }
    }
}
