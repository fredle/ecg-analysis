import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case network(URLError)
    case http(Int, String?)
    case decoding(Error)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:            return "Invalid URL"
        case .network(let e):        return e.localizedDescription
        case .http(let code, let b): return "HTTP \(code)" + (b.map { ": \($0.prefix(200))" } ?? "")
        case .decoding(let e):       return "Decode failed: \(e)"
        case .unexpected(let s):     return s
        }
    }
}

enum APIDate {
    static let spaced: DateFormatter = make("yyyy-MM-dd HH:mm:ss")
    static let spacedMillis: DateFormatter = make("yyyy-MM-dd HH:mm:ss.SSS")
    static let day: DateFormatter = make("yyyy-MM-dd")
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // Backend emits naive datetimes (no timezone). Parse them against UTC
    // so DST transitions can't produce non-existent / ambiguous local times
    // (e.g. 01:00 on the UK spring-forward day). Display code uses the
    // matching UTC calendar/formatters below so hour labels line up with
    // what the backend stored.
    static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }()

    static let displayDateTime: DateFormatter = makeDisplay("yyyy-MM-dd HH:mm:ss")
    static let displayTime: DateFormatter     = makeDisplay("HH:mm:ss")
    static let displayDate: DateFormatter     = makeDisplay("EEE, MMM d, yyyy")
    static let displayMonthDay: DateFormatter = makeDisplay("MMM d")

    private static func make(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = utc
        df.dateFormat = format
        return df
    }

    private static func makeDisplay(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale.current
        df.timeZone = utc
        df.dateFormat = format
        return df
    }
}

extension Date {
    /// Re-anchor a user-picked Date (interpreted in their local calendar)
    /// to the corresponding UTC day start. Example: a BST user picking
    /// "Apr 15" returns 2026-04-15T00:00:00Z, so queries line up with the
    /// backend's naive day buckets.
    func asUTCDayStart() -> Date {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return APIDate.utcCalendar.date(from: comps) ?? self
    }
}

extension JSONDecoder {
    static func apiDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = APIDate.spacedMillis.date(from: s) { return date }
            if let date = APIDate.spaced.date(from: s) { return date }
            if let date = APIDate.day.date(from: s) { return date }
            if let date = APIDate.iso.date(from: s) { return date }
            if let date = APIDate.isoNoFraction.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable date: \(s)")
        }
        return d
    }
}

struct DataRange: Codable, Sendable {
    let min: Date?
    let max: Date?
}

struct DailyBurden: Codable, Sendable, Identifiable {
    let date: Date
    let episodes: Int
    let bigeminy_seconds: Double
    var id: Date { date }
}

struct Summary: Codable, Sendable {
    let data_range: DataRange
    let total_episodes: Int
    let total_bigeminy_seconds: Double
    let total_beats: Int
    let total_pvc: Int
    let daily: [DailyBurden]
}

enum EpisodeType: String, Codable, Sendable, CaseIterable {
    case bigeminy, trigeminy, couplet, vtach
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = EpisodeType(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .bigeminy:  return "Bigeminy"
        case .trigeminy: return "Trigeminy"
        case .couplet:   return "Couplet"
        case .vtach:     return "VTach"
        case .unknown:   return "Unknown"
        }
    }
}

struct EpisodeDTO: Codable, Sendable, Identifiable {
    let episode_type: EpisodeType
    let start_time: Date
    let end_time: Date
    let duration_seconds: Double
    let total_beats: Int
    let normal_beats: Int
    let pvc_beats: Int
    let avg_confidence: Double
    let start_sample_100hz: Int
    let end_sample_100hz: Int

    var id: String { "\(episode_type.rawValue)-\(start_time.timeIntervalSince1970)" }
}

struct EpisodeSummary: Codable, Sendable {
    let total_episodes: Int
    let total_beats: Int
    let total_pvc: Int
    let total_bigeminy_seconds: Double
}

struct EpisodesResponse: Codable, Sendable {
    let start: Date
    let end: Date
    let episodes: [EpisodeDTO]
    let summary: EpisodeSummary
    let data_range: DataRange
}

struct HourlyBucket: Codable, Sendable, Identifiable {
    let hour_start: Date
    let total_beats: Int
    let hr_bpm: Double
    let pvc_beats: Int
    var id: Date { hour_start }
}

struct RemoteRecording: Codable, Sendable, Identifiable {
    let file: String
    let rec_start: Date
    let rec_end: Date
    var id: String { file }
}

struct HourlyResponse: Codable, Sendable {
    let hourly: [HourlyBucket]
    let recordings: [RemoteRecording]
}

struct ECGRawWindow: Codable, Sendable {
    let start_ms: Int64
    let sample_rate: Int
    let window_sec: Int
    let samples: [Int]
    let data_ranges: [[Int64]]
}

enum Granularity: String, Codable, Sendable, CaseIterable, Identifiable {
    case day, hour
    var id: String { rawValue }
}

struct PVCBurdenPoint: Codable, Sendable, Identifiable {
    let bucket: Date
    let total_beats: Int
    let pvc_beats: Int
    let pvc_burden: Double
    var id: Date { bucket }
}

struct PVCBurdenResponse: Codable, Sendable {
    let data: [PVCBurdenPoint]
    let granularity: String
}

struct ModelStatus: Codable, Sendable {
    let status: String
    let error: String?
}

struct ProgressEvent: Sendable {
    enum Kind: String, Sendable { case log, done, error, ping, message }
    let kind: Kind
    let data: String
}
