import Foundation

/// Only actual recorded events are used. Missing records do not establish fasting or wakefulness.
struct LifeTimeline {
    struct SleepInterval {
        let sleep: LifeEvent
        let wake: LifeEvent
        var duration: TimeInterval { wake.at.timeIntervalSince(sleep.at) }
    }

    let lastFood: LifeEvent?
    let lastSleep: LifeEvent?
    let lastWake: LifeEvent?
    let sleeps: [SleepInterval]
    private let past: [LifeEvent]

    init(events: [LifeEvent], now: Date) {
        past = events.filter { $0.at <= now }.sorted {
            $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at
        }
        lastFood = past.last { $0.kind == .food }
        lastSleep = past.last { $0.kind == .sleep }
        lastWake = past.last { $0.kind == .wake }
        var pendingSleep: LifeEvent?
        var intervals: [SleepInterval] = []
        // Repeated starts replace the pending start; repeated wakes cannot count sleep twice.
        for event in past {
            switch event.kind {
            case .food: break
            case .sleep: pendingSleep = event
            case .wake:
                if let start = pendingSleep, event.at > start.at {
                    intervals.append(SleepInterval(sleep: start, wake: event))
                }
                pendingSleep = nil
            }
        }
        sleeps = intervals
    }

    /// A later sleep ends a recorded waking interval; its following wake starts a new one.
    var awakeSince: Date? {
        guard let wake = lastWake else { return nil }
        if let sleep = lastSleep, sleep.at >= wake.at { return nil }
        return wake.at
    }

    func events(since start: Date) -> [LifeEvent] {
        past.filter { $0.at >= start }.reversed()
    }

    /// Completed sleep only, clipped at the episode boundary; an unpaired start has unknown duration.
    func recordedSleep(since start: Date) -> TimeInterval {
        sleeps.reduce(0) { result, interval in
            result + max(0, interval.wake.at.timeIntervalSince(max(start, interval.sleep.at)))
        }
    }
}
