import Foundation

/// Tracks long-running work reported over the hum:// URL scheme:
/// Claude Code sessions (via hooks) and shell commands (via hum-run).
final class ActivityTracker: ObservableObject {
    enum Kind { case claude, task }

    struct Job {
        let id: String
        var label: String
        let kind: Kind
        let started: Date
        var waiting = false
    }

    @Published private(set) var jobs: [String: Job] = [:]

    var onFinish: ((Job, Bool, TimeInterval) -> Void)?
    var onAttention: ((Job) -> Void)?

    var isBusy: Bool { !jobs.isEmpty }
    var isWaiting: Bool { jobs.values.contains { $0.waiting } }
    var oldestStart: Date? { jobs.values.map(\.started).min() }

    /// Events: start (prompt submitted), stop / fail (turn finished), attention (needs permission),
    /// resume (a tool ran), end (session closed).
    func claude(event: String, session: String, project: String) {
        let id = "claude-" + (session.isEmpty ? project : session)
        let label = project.isEmpty ? "Claude Code" : project
        switch event {
        case "start":
            if jobs[id] == nil { jobs[id] = Job(id: id, label: label, kind: .claude, started: Date()) }
            else { jobs[id]?.waiting = false }
        case "stop":
            finish(id, ok: true)
        case "fail":
            finish(id, ok: false)
        case "resume":
            // A tool ran, so any permission prompt was answered.
            if jobs[id]?.waiting == true { jobs[id]?.waiting = false }
        case "attention":
            // Claude also pings when idle after a turn; only mid-turn requests matter.
            guard jobs[id] != nil else { return }
            jobs[id]?.waiting = true
            if let job = jobs[id] { onAttention?(job) }
        case "end":
            jobs[id] = nil
        default:
            break
        }
    }

    /// Events: start, done (with ok).
    func task(event: String, id: String, label: String, ok: Bool) {
        let key = "task-" + id
        switch event {
        case "start": jobs[key] = Job(id: key, label: label.isEmpty ? "Task" : label, kind: .task, started: Date())
        case "done": finish(key, ok: ok)
        default: break
        }
    }

    private func finish(_ id: String, ok: Bool) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        onFinish?(job, ok, Date().timeIntervalSince(job.started))
    }
}
