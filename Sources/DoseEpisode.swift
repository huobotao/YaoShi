import Foundation

/// 记录时间的分组，不代表药效、浓度或连续清醒；不受模型回溯窗口限制。
struct DoseEpisode {
    let start: Dose?
    let doses: [Dose]
    let autoStarted: Bool

    init(doses: [Dose], selection: DoseEpisodeSelection?, now: Date,
         newRoundGapHours: Int = 48) {
        let eligible = doses.filter {
            $0.at.timeIntervalSince1970.isFinite && $0.at <= now
        }.sorted {
            $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at
        }

        let gap = TimeInterval(min(max(newRoundGapHours, 1), 720)) * 3600
        var automaticStart: Dose?
        for (earlier, later) in zip(eligible, eligible.dropFirst()) {
            if later.at.timeIntervalSince(earlier.at) > gap {
                automaticStart = later
            }
        }

        let selected = selection?.doseID.flatMap { id in eligible.first { $0.id == id } }
        let chosen: Dose?
        if let selection, selection.doseID == nil {
            // An explicit clear remains a deliberate opt-out until a start is selected.
            chosen = nil
            autoStarted = false
        } else if let automaticStart, selected == nil || selected!.at < automaticStart.at {
            chosen = automaticStart
            autoStarted = true
        } else {
            // The first actual dose begins the initial round without an extra setup step.
            // A deleted/invalid explicit selection still requires correction.
            chosen = selected ?? (selection == nil ? eligible.first : nil)
            autoStarted = automaticStart.map { $0.id == selected?.id } ?? false
        }

        start = chosen
        self.doses = chosen.map { first in eligible.filter { $0.at >= first.at } } ?? []
    }
}
