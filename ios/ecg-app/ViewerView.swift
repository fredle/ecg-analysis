import SwiftUI

struct ViewerView: View {
    @State private var vm = ViewerViewModel()
    @State private var scrolledRowId: Int64?

    private let initialCenter: Date?
    private let initialWindowSec: Int?

    init(center: Date? = nil, windowSec: Int? = nil) {
        self.initialCenter = center
        self.initialWindowSec = windowSec
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
        }
        .navigationTitle("Viewer")
        .environment(\.calendar, APIDate.utcCalendar)
        .environment(\.timeZone, APIDate.utc)
        .task {
            if let c = initialCenter { vm.center = c }
            if let w = initialWindowSec {
                vm.secondsPerRow = ViewerViewModel.rowOptions.min(by: {
                    abs($0 - w) < abs($1 - w)
                }) ?? vm.secondsPerRow
            }
            vm.loadIfIdle()
        }
        .onChange(of: stateKey) { _, newKey in
            if newKey == "loaded" {
                scrolledRowId = anchorRowId()
            } else if newKey == "loading" {
                scrolledRowId = nil
            }
        }
    }

    private var stateKey: String {
        switch vm.state {
        case .idle:    return "idle"
        case .loading: return "loading"
        case .loaded:  return "loaded"
        case .error:   return "error"
        }
    }

    private func anchorRowId() -> Int64? {
        let centerMs = Int64(vm.center.timeIntervalSince1970 * 1000)
        var best: Int64?
        var bestDelta: Int64 = .max
        for row in vm.rows {
            let d = abs(row.startMs - centerMs)
            if d < bestDelta {
                bestDelta = d
                best = row.id
            }
        }
        return best
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 10) {
            DatePicker("Center",
                       selection: Binding(
                           get: { vm.center },
                           set: { vm.jumpTo($0) }
                       ),
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)

            HStack(spacing: 12) {
                zoomControl(
                    label: "Time",
                    value: formatTimeZoom(vm.secondsPerRow),
                    canDecrease: canStepRow(-1),
                    canIncrease: canStepRow(1),
                    onDecrease: { stepRow(-1) },
                    onIncrease: { stepRow(1) }
                )
                zoomControl(
                    label: "Gain",
                    value: formatGainZoom(vm.ampGain),
                    canDecrease: canStepGain(-1),
                    canIncrease: canStepGain(1),
                    onDecrease: { stepGain(-1) },
                    onIncrease: { stepGain(1) }
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle:
            Color.clear
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary).font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let msg):
            VStack(spacing: 10) {
                Text(msg).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") { vm.reload() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            scroller
        }
    }

    private var scroller: some View {
        let rows = vm.rows
        return ScrollView {
            LazyVStack(spacing: 2) {
                Color.clear
                    .frame(height: 1)
                    .onAppear { vm.loadEarlierIfNeeded() }

                ForEach(rows) { row in
                    PaperECGRow(
                        samples: vm.samples,
                        startIndex: row.bufferOffset,
                        sampleCount: row.sampleCount,
                        gaps: row.gaps,
                        sampleRate: Double(vm.sampleRate),
                        secondsPerRow: Double(vm.secondsPerRow),
                        ampGain: vm.ampGain,
                        valueMid: vm.valueMid,
                        valueHalfSpan: vm.valueHalfSpan,
                        startLabel: timeLabel(row.startMs)
                    )
                    .frame(height: rowHeight)
                    .padding(.horizontal, 6)
                    .id(row.id)
                }

                Color.clear
                    .frame(height: 1)
                    .onAppear { vm.loadLaterIfNeeded() }
            }
            .padding(.vertical, 4)
        }
        .scrollPosition(id: $scrolledRowId, anchor: .center)
    }

    private var rowHeight: CGFloat { 130 }

    private func timeLabel(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        return APIDate.displayTime.string(from: d)
    }

    // MARK: Zoom controls

    private func zoomControl(label: String,
                             value: String,
                             canDecrease: Bool,
                             canIncrease: Bool,
                             onDecrease: @escaping () -> Void,
                             onIncrease: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Button(action: onDecrease) {
                Image(systemName: "minus").frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(!canDecrease)

            Text(value)
                .font(.caption.monospaced())
                .frame(minWidth: 48)

            Button(action: onIncrease) {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(!canIncrease)
        }
    }

    private func canStepRow(_ dir: Int) -> Bool {
        guard let i = ViewerViewModel.rowOptions.firstIndex(of: vm.secondsPerRow) else { return true }
        let j = i + dir
        return j >= 0 && j < ViewerViewModel.rowOptions.count
    }

    private func stepRow(_ dir: Int) {
        guard let i = ViewerViewModel.rowOptions.firstIndex(of: vm.secondsPerRow) else { return }
        let j = i + dir
        guard j >= 0, j < ViewerViewModel.rowOptions.count else { return }
        vm.secondsPerRow = ViewerViewModel.rowOptions[j]
    }

    private func canStepGain(_ dir: Int) -> Bool {
        guard let i = ViewerViewModel.gainOptions.firstIndex(of: vm.ampGain) else { return true }
        let j = i + dir
        return j >= 0 && j < ViewerViewModel.gainOptions.count
    }

    private func stepGain(_ dir: Int) {
        guard let i = ViewerViewModel.gainOptions.firstIndex(of: vm.ampGain) else {
            vm.ampGain = 1.0
            return
        }
        let j = i + dir
        guard j >= 0, j < ViewerViewModel.gainOptions.count else { return }
        vm.ampGain = ViewerViewModel.gainOptions[j]
    }

    private func formatTimeZoom(_ sec: Int) -> String { "\(sec)s" }
    private func formatGainZoom(_ g: Double) -> String {
        g == g.rounded() ? "\(Int(g))×" : String(format: "%.1f×", g)
    }
}
