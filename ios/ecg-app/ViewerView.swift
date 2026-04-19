import SwiftUI

struct ViewerView: View {
    @State private var vm = ViewerViewModel()

    private let initialCenter: Date?
    private let initialWindowSec: Int?

    init(center: Date? = nil, windowSec: Int? = nil) {
        self.initialCenter = center
        self.initialWindowSec = windowSec
    }

    var body: some View {
        List {
            Section("Position") {
                DatePicker("Center",
                           selection: $vm.center,
                           displayedComponents: [.date, .hourAndMinute])
                Picker("Window", selection: $vm.windowSec) {
                    Text("30s").tag(30)
                    Text("60s").tag(60)
                    Text("120s").tag(120)
                }
                .pickerStyle(.segmented)
            }

            Section("Waveform") {
                content
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .navigationTitle("Viewer")
        .environment(\.calendar, APIDate.utcCalendar)
        .environment(\.timeZone, APIDate.utc)
        .task {
            if let c = initialCenter { vm.center = c }
            if let w = initialWindowSec { vm.windowSec = w }
            vm.loadIfIdle()
        }
        .refreshable { vm.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle:
            Text("Choose a time to load.").foregroundStyle(.secondary)
        case .loading:
            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).font(.caption).foregroundStyle(.red)
                Button("Retry") { vm.reload() }
            }
        case .ready(let payload):
            ReadyView(payload: payload)
        }
    }
}

private struct ReadyView: View {
    let payload: ViewerViewModel.Payload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WaveformView(
                samples: payload.samples,
                sampleRate: Double(payload.sampleRate),
                windowSize: max(payload.samples.count, 1),
                gaps: payload.gaps
            )
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text(rangeLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if !payload.gaps.isEmpty {
                    Label("Gaps", systemImage: "square.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.gray)
                        .font(.caption)
                }
            }
        }
    }

    private var rangeLabel: String {
        let start = Date(timeIntervalSince1970: Double(payload.startMs) / 1000.0)
        let end = start.addingTimeInterval(Double(payload.windowSec))
        let df = APIDate.displayTime
        return "\(df.string(from: start)) – \(df.string(from: end))  (\(payload.sampleRate) Hz)"
    }
}
