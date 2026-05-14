import ActivityKit
import Foundation

struct ECGRecordingAttributes: ActivityAttributes {
    let deviceName: String

    struct ContentState: Codable, Hashable {
        var bpm: Int
        var isConnected: Bool
        var batteryPct: Int
        var sampleCount: Int
        var startedAt: Date
    }
}
