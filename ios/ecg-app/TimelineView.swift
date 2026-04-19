import SwiftUI

struct ViewerTarget: Hashable {
    let center: Date
    let windowSec: Int
}

private let weekdayFormatter: DateFormatter = {
    let df = DateFormatter()
    df.locale = Locale.current
    df.timeZone = APIDate.utc
    df.dateFormat = "EEEE"
    return df
}()

struct TimelineView: View {
    @State private var vm = TimelineViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section { daySelector }
                Section { densityStrip }
                Section("Episodes") { episodesContent }
            }
            .navigationTitle("Timeline")
            .navigationDestination(for: ViewerTarget.self) { target in
                ViewerView(center: target.center, windowSec: target.windowSec)
            }
            .refreshable { vm.reload() }
        }
        .environment(\.calendar, APIDate.utcCalendar)
        .environment(\.timeZone, APIDate.utc)
        .task { await vm.initialize() }
    }

    private var daySelector: some View {
        HStack(spacing: 16) {
            Button { vm.step(-1) } label: {
                Image(systemName: "chevron.left").font(.title3)
            }
            .buttonStyle(.borderless)

            VStack(spacing: 2) {
                Text(weekdayFormatter.string(from: vm.selectedDay))
                    .font(.caption).foregroundStyle(.secondary)
                Text(APIDate.displayDate.string(from: vm.selectedDay))
                    .font(.headline)
                if let range = vm.dataRange, let min = range.min, let max = range.max {
                    Text("Available: \(APIDate.displayMonthDay.string(from: min)) – \(APIDate.displayMonthDay.string(from: max))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            Button { vm.step(1) } label: {
                Image(systemName: "chevron.right").font(.title3)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var densityStrip: some View {
        switch vm.state {
        case .ready(let data):
            DensityStrip(day: data.day, hourly: data.hourly, episodes: data.episodes)
                .frame(height: 56)
        default:
            Rectangle().fill(.secondary.opacity(0.08)).frame(height: 56)
                .overlay(
                    Text("24h density").font(.caption).foregroundStyle(.secondary)
                )
        }
    }

    @ViewBuilder
    private var episodesContent: some View {
        switch vm.state {
        case .idle, .loading:
            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).font(.caption).foregroundStyle(.red)
                Button("Retry") { vm.reload() }
            }
        case .ready(let data):
            if data.episodes.isEmpty {
                Text("No episodes this day.").foregroundStyle(.secondary)
            } else {
                ForEach(data.episodes) { ep in
                    NavigationLink(value: ViewerTarget(center: ep.start_time, windowSec: 60)) {
                        EpisodeRow(episode: ep)
                    }
                }
            }
        }
    }
}

extension EpisodeType {
    var color: Color {
        switch self {
        case .vtach:     return .red
        case .bigeminy:  return .orange
        case .trigeminy: return .yellow
        case .couplet:   return .blue
        case .unknown:   return .gray
        }
    }
}

private struct EpisodeRow: View {
    let episode: EpisodeDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TypeBadge(type: episode.episode_type)
                Text(APIDate.displayTime.string(from: episode.start_time))
                    .font(.body.monospaced())
                Spacer()
                Text(formatDuration(episode.duration_seconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("\(episode.pvc_beats) PVC", systemImage: "waveform.path")
                Text("Conf \(Int(episode.avg_confidence * 100))%")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let m = total / 60
        let sec = total % 60
        return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }
}

private struct TypeBadge: View {
    let type: EpisodeType

    var body: some View {
        Text(type.displayName)
            .font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(type.color.opacity(0.2))
            .foregroundStyle(type.color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct DensityStrip: View {
    let day: Date
    let hourly: [HourlyBucket]
    let episodes: [EpisodeDTO]

    var body: some View {
        GeometryReader { geo in
            let dayStart = APIDate.utcCalendar.startOfDay(for: day)
            let dayEnd = APIDate.utcCalendar.date(byAdding: .day, value: 1, to: dayStart) ?? day
            let totalSec = dayEnd.timeIntervalSince(dayStart)

            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    for h in 1..<24 {
                        let x = size.width * CGFloat(h) / 24
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(p, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                    }
                }

                ForEach(hourly, id: \.hour_start) { bucket in
                    let startFrac = CGFloat(bucket.hour_start.timeIntervalSince(dayStart) / totalSec)
                    let widthFrac: CGFloat = 1.0 / 24
                    Rectangle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: max(1, geo.size.width * widthFrac),
                               height: geo.size.height)
                        .offset(x: geo.size.width * startFrac)
                }

                ForEach(episodes) { ep in
                    let startFrac = CGFloat(ep.start_time.timeIntervalSince(dayStart) / totalSec)
                    let widthFrac = CGFloat(ep.duration_seconds / totalSec)
                    Rectangle()
                        .fill(ep.episode_type.color)
                        .frame(width: max(2, geo.size.width * widthFrac),
                               height: geo.size.height * 0.6)
                        .offset(x: geo.size.width * startFrac,
                                y: geo.size.height * 0.2)
                }
            }
        }
    }
}

#Preview { TimelineView() }
