import Foundation

@MainActor
@Observable
final class TimelineViewModel {
    struct DayData: Sendable {
        let day: Date
        let episodes: [EpisodeDTO]
        let hourly: [HourlyBucket]
        let recordings: [RemoteRecording]
    }

    enum ViewState {
        case idle
        case loading
        case ready(DayData)
        case error(String)
    }

    var state: ViewState = .idle
    var selectedDay: Date = Date().asUTCDayStart()
    var dataRange: DataRange?

    private var loadTask: Task<Void, Never>?
    private var didInitialize = false

    func initialize() async {
        if didInitialize {
            if case .idle = state { reload() }
            return
        }
        didInitialize = true
        do {
            let summary = try await APIClient.shared.summary()
            dataRange = summary.data_range
            if let maxDate = summary.data_range.max {
                selectedDay = APIDate.utcCalendar.startOfDay(for: maxDate)
            }
        } catch {
            // Keep selectedDay default; user can still navigate.
        }
        reload()
    }

    func step(_ days: Int) {
        if let next = APIDate.utcCalendar.date(byAdding: .day, value: days, to: selectedDay) {
            selectedDay = APIDate.utcCalendar.startOfDay(for: next)
            reload()
        }
    }

    func reload() {
        loadTask?.cancel()
        let day = selectedDay
        loadTask = Task {
            state = .loading
            let start = day
            guard let endExclusive = APIDate.utcCalendar.date(byAdding: .day, value: 1, to: day) else {
                state = .error("Could not compute day end")
                return
            }
            let end = endExclusive.addingTimeInterval(-1)
            do {
                async let epsCall = APIClient.shared.episodes(start: start, end: end)
                async let hrlyCall = APIClient.shared.hourly(start: start, end: end)
                let (eps, hrly) = try await (epsCall, hrlyCall)
                if Task.isCancelled { return }
                state = .ready(DayData(
                    day: day,
                    episodes: eps.episodes,
                    hourly: hrly.hourly,
                    recordings: hrly.recordings
                ))
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                state = .error(error.localizedDescription)
            }
        }
    }
}
