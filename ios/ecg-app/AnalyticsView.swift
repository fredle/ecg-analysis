import SwiftUI
import Charts

struct AnalyticsView: View {
    @State private var vm = AnalyticsViewModel()
    @State private var showHR = false
    @State private var showBeats = false
    @State private var showCoverage = false

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

                Section("Overlays") {
                    Toggle("Avg heart rate", isOn: $showHR)
                    Toggle("Number of beats", isOn: $showBeats)
                    Toggle("% data coverage", isOn: $showCoverage)
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
            ReadyView(response: resp, granularity: vm.granularity,
                      showHR: showHR, showBeats: showBeats, showCoverage: showCoverage)
        }
    }
}

private struct OverlayPoint: Identifiable {
    let bucket: Date
    let value: Double      // scaled into the burden axis
    let series: String
    var id: String { "\(series)-\(bucket.timeIntervalSince1970)" }
}

private struct ReadyView: View {
    let response: PVCBurdenResponse
    let granularity: Granularity
    let showHR: Bool
    let showBeats: Bool
    let showCoverage: Bool

    private var totalBeats: Int  { response.data.reduce(0) { $0 + $1.total_beats } }
    private var totalPVC:  Int  { response.data.reduce(0) { $0 + $1.pvc_beats } }
    private var burden:    Double {
        totalBeats > 0 ? Double(totalPVC) / Double(totalBeats) * 100.0 : 0
    }

    // Overlays share the burden Y-axis, so each metric is normalised into
    // [0, burdenScale]. Distinct colours + a legend keep them readable.
    private let hrColor = Color.purple
    private let beatsColor = Color.teal
    private let coverageColor = Color.gray

    private var burdenScale: Double {
        max(response.data.map(\.pvc_burden).max() ?? 0, 5)
    }

    private var overlaySeries: [OverlayPoint] {
        var pts: [OverlayPoint] = []
        let scale = burdenScale
        func add(_ name: String, lo: Double, hi: Double, _ value: (PVCBurdenPoint) -> Double?) {
            let span = hi > lo ? hi - lo : 1
            for p in response.data {
                guard let v = value(p) else { continue }
                let t = min(max((v - lo) / span, 0), 1)
                pts.append(OverlayPoint(bucket: p.bucket, value: t * scale, series: name))
            }
        }
        if showHR {
            let hrs = response.data.compactMap(\.avg_hr).filter { $0 > 0 }
            if let lo = hrs.min(), let hi = hrs.max() {
                add("Avg HR", lo: lo, hi: hi) { ($0.avg_hr ?? 0) > 0 ? $0.avg_hr : nil }
            }
        }
        if showBeats {
            let hi = response.data.map { Double($0.total_beats) }.max() ?? 0
            add("Beats", lo: 0, hi: hi) { Double($0.total_beats) }
        }
        if showCoverage {
            add("Coverage", lo: 0, hi: 100) { $0.coverage_pct }
        }
        return pts
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
                    ForEach(overlaySeries) { pt in
                        LineMark(
                            x: .value("Bucket", pt.bucket, unit: granularity == .day ? .day : .hour),
                            y: .value("Overlay", pt.value),
                            series: .value("Series", pt.series)
                        )
                        .foregroundStyle(by: .value("Series", pt.series))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartForegroundStyleScale([
                    "Avg HR": hrColor, "Beats": beatsColor, "Coverage": coverageColor,
                ])
                .chartLegend(overlaySeries.isEmpty ? .hidden : .visible)
                .chartYAxisLabel("Burden %")
                .frame(height: 220)

                if !overlaySeries.isEmpty {
                    Text("Overlays are scaled to fit the burden axis and show relative trends, not absolute values.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
