import Foundation

/// Decides what a live session's status badge should say.
///
/// This is the app's one genuinely subjective rule. Everything else is
/// observation — pids, timestamps, git refs — but "is this instance working,
/// waiting on me, or forgotten?" depends on how you actually work, so it is
/// isolated here rather than scattered through the views.
///
/// Signals available:
///  - `digest.lastActivity`   when the transcript was last appended to
///  - `digest.endsAwaitingUser` Claude's last turn ended with `stop_reason: end_turn`,
///                            i.e. it stopped and said something rather than
///                            continuing into another tool call
///  - `process.cpuPercent`    a busy instance is usually mid-inference or running a tool
///  - `process.uptime`        how long the instance has been alive
enum SessionStatusPolicy {

    /// Recent transcript activity counts as working. Deliberately generous: a
    /// single tool call can run far longer than this without writing a record.
    static let workingGrace: TimeInterval = 10 * 60

    /// CPU above this means the instance is doing something, whatever the
    /// transcript says — tool calls can run for minutes without a new record.
    static let busyCPUPercent: Double = 4

    /// A process alive this long with an entirely empty transcript was started
    /// and never used.
    static let unusedAfter: TimeInterval = 2 * 60

    /// Chosen policy: **bias toward Working.**
    ///
    /// A session is reported as Working unless there is positive evidence it is
    /// waiting on you — namely that Claude ended its turn and said something.
    /// Anything still mid-turn is treated as working however long it has been
    /// quiet, because a long build, test run, or `sleep` writes nothing to the
    /// transcript and is indistinguishable from an abandoned session. The cost
    /// of that choice is an occasional stale "Working"; the benefit is never
    /// being told a session is idle while it is grinding through your test
    /// suite. "Needs you" stays trustworthy, which is what makes it worth
    /// looking at.
    static func classify(digest: TranscriptDigest, process: ClaudeProcess) -> SessionStatus {
        // No transcript at all: either just launched, or opened and never used.
        guard let lastActivity = digest.lastActivity else {
            return process.uptime > unusedAfter ? .idle : .working
        }

        // Burning CPU is unambiguous.
        if process.cpuPercent >= busyCPUPercent { return .working }

        // Recently wrote a record.
        if Date().timeIntervalSince(lastActivity) <= workingGrace { return .working }

        // Mid-turn — Claude was in the middle of something and never came back
        // with a reply, so assume the work is still in flight.
        if !digest.endsAwaitingUser { return .working }

        // Claude finished its turn and stopped: the ball is genuinely with you.
        return .awaitingInput
    }
}
