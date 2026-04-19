import Foundation

@MainActor
@Observable
final class AnalyticsViewModel {
    enum ViewState {
        case idle
        case loading
        case ready(PVCBurdenResponse)
        case error(String)
    }

    var state: ViewState = .idle
    var granularity: Granularity = .day {
        didSet { if granularity != oldValue { reload() } }
    }
    var startDate: Date = APIDate.utcCalendar.date(byAdding: .day, value: -30, to: Date()) ?? Date() {
        didSet { if startDate != oldValue { reload() } }
    }
    var endDate: Date = Date() {
        didSet { if endDate != oldValue { reload() } }
    }

    private var loadTask: Task<Void, Never>?

    func loadIfIdle() {
        if case .idle = state { reload() }
    }

    func reload() {
        loadTask?.cancel()
        let g = granularity
        let start = startDate.asUTCDayStart()
        let end = APIDate.utcCalendar
            .date(bySettingHour: 23, minute: 59, second: 59, of: endDate.asUTCDayStart()) ?? endDate
        loadTask = Task {
            state = .loading
            do {
                let response = try await APIClient.shared.pvcBurden(
                    granularity: g, start: start, end: end
                )
                if Task.isCancelled { return }
                state = .ready(response)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                state = .error(error.localizedDescription)
            }
        }
    }
}
