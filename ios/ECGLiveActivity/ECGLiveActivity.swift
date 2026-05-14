import ActivityKit
import SwiftUI
import WidgetKit

struct ECGLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ECGRecordingAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.75))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.red)
                        Text("\(context.state.bpm)")
                            .font(.title2.bold().monospacedDigit())
                        Text("bpm")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "record.circle")
                            .foregroundStyle(.red)
                        Text(context.state.startedAt, style: .timer)
                            .font(.title3.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label("\(context.state.batteryPct)%", systemImage: "battery.100")
                        Spacer()
                        Label(formatSamples(context.state.sampleCount), systemImage: "waveform.path.ecg")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.green)
                    .widgetAccentable()
            } compactTrailing: {
                Text("\(context.state.bpm)")
                    .font(.caption.bold().monospacedDigit())
            } minimal: {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.green)
                    .widgetAccentable()
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<ECGRecordingAttributes>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                    Text("\(context.state.bpm)")
                        .font(.title.bold().monospacedDigit())
                    Text("bpm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(context.attributes.deviceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(context.state.startedAt, style: .timer)
                    .font(.title2.monospacedDigit())
                HStack(spacing: 8) {
                    Label("\(context.state.batteryPct)%", systemImage: "battery.100")
                    Label(formatSamples(context.state.sampleCount), systemImage: "waveform.path.ecg")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func formatSamples(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fk", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
