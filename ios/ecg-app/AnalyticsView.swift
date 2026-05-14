import SwiftUI
import Charts

struct AnalyticsView: View {
    @State private var vm = AnalyticsViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Range") {
                    DatePicker("From", selection: $vm.startDate, displayedComponents: .date)
                    DatePicker("To", selection: $vm.endDate, in: vm.startDate..., displayedComponents: .date)
                    Picker("Granularity", selection: $vm.granularity) {
                        Text("Day").tag(Granularity.day)
                        Text("Hour").tag(Granularity.hour)
                    }
                    .pickerStyle(.segmented)
                }

                Section("PVC burden") {
                    content
                }
            }
            .navigationTitle("Analytics")
            .refreshable { vm.reload() }
        }
        .environment(\.calendar, APIDate.utcCalendar)
        .environment(\.timeZone, APIDate.utc)
        .task { vm.loadIfIdle() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle:
            Text("Select a range to load.").foregroundStyle(.secondary)
        case .loading:
            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).font(.caption).foregroundStyle(.red)
                Button("Retry") { vm.reload() }
            }
        case .ready(let resp):
            ReadyView(response: resp, granularity: vm.granularity)
        }
    }
}

private struct ReadyView: View {
    let response: PVCBurdenResponse
    let granularity: Granularity

    private var totalBeats: Int  { response.data.reduce(0) { $0 + $1.total_beats } }
    private var totalPVC:  Int  { response.data.reduce(0) { $0 + $1.pvc_beats } }
    private var burden:    Double {
        totalBeats > 0 ? Double(totalPVC) / Double(totalBeats) * 100.0 : 0
    }

    private var nightRanges: [DateInterval] {
        guard let first = response.data.first?.bucket,
              let last = response.data.last?.bucket else { return [] }
        let cal = APIDate.utcCalendar
        var ranges: [DateInterval] = []
        // Start one day before to catch an evening that extends into the data range
        var day = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: first))!
        let limit = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last))!
        while day <= limit {
            let evening = cal.date(bySettingHour: 22, minute: 0, second: 0, of: day)!
            let nextDay = cal.date(byAdding: .day, value: 1, to: day)!
            let morning = cal.date(bySettingHour: 6, minute: 0, second: 0, of: nextDay)!
            if evening < last && morning > first {
                ranges.append(DateInterval(start: evening, end: morning))
            }
            day = nextDay
        }
        return ranges
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 24) {
                KPI(label: "Beats", value: totalBeats.formatted(.number.notation(.compactName)))
                KPI(label: "PVC",   value: totalPVC.formatted(.number.notation(.compactName)))
                KPI(label: "Burden", value: String(format: "%.2f%%", burden))
            }

            if response.data.isEmpty {
                Text("No data in range.").foregroundStyle(.secondary)
            } else {
                Chart {
                    if granularity == .hour {
                        ForEach(nightRanges, id: \.start) { range in
                            RectangleMark(
                                xStart: .value("Night Start", range.start),
                                xEnd: .value("Night End", range.end)
                            )
                            .foregroundStyle(Color.primary.opacity(0.06))
                        }
                    }
                    ForEach(response.data) { point in
                        BarMark(
                            x: .value("Bucket", point.bucket, unit: granularity == .day ? .day : .hour),
                            y: .value("Burden %", point.pvc_burden)
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .chartYAxisLabel("Burden %")
                .frame(height: 220)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct KPI: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
    }
}

#Preview { AnalyticsView() }
