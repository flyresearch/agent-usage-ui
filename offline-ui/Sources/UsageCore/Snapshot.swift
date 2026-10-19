import Foundation

public enum UsageError: Error { case invalidSnapshot, overflow, collectionFailed, outputTooLarge, timedOut, configurationChanged, sourceFailure(String) }
public struct Tokens: Codable, Equatable, Sendable {
    public var input: UInt64
    public var cache_read: UInt64
    public var cache_write: UInt64
    public var output: UInt64
    public var reasoning: UInt64
    public init(input: UInt64 = 0, cache_read: UInt64 = 0, cache_write: UInt64 = 0, output: UInt64 = 0, reasoning: UInt64 = 0) {
        self.input=input; self.cache_read=cache_read; self.cache_write=cache_write; self.output=output; self.reasoning=reasoning
    }
    public var total: UInt64 { get throws { try checked([input,cache_read,cache_write,output,reasoning]) } }
    public func adding(_ other: Tokens) throws -> Tokens {
        let value = try Tokens(input: checked([input,other.input]), cache_read: checked([cache_read,other.cache_read]), cache_write: checked([cache_write,other.cache_write]), output: checked([output,other.output]), reasoning: checked([reasoning,other.reasoning]))
        _ = try value.total
        return value
    }
}
private func checked(_ values: [UInt64]) throws -> UInt64 {
    try values.reduce(0) { a,b in let (sum,overflow)=a.addingReportingOverflow(b); if overflow {throw UsageError.overflow}; return sum }
}
public struct UsageInterval: Codable, Sendable {
    public let start: String?
    public let end: String?
}
public struct UsageRow: Codable, Identifiable, Sendable {
    public let messages:MessageCount?
    public let source_id: String
    public let agent: String
    public let model: String
    public let day: String?
    public let hour: Int?
    public let execution_role: String?
    public let time_basis: String
    public let tokens: Tokens
    public let interval: UsageInterval?
    public let usage_kind: String?
    public let backend: String?
    public let provider: String?
    public var id: String { [source_id,agent,model,day ?? "unallocated",hour.map(String.init) ?? "unallocated-hour",execution_role ?? "unknown-role",time_basis,usage_kind ?? "",backend ?? "",provider ?? ""].joined(separator: "|") }
}
public struct SourceStatus: Codable, Identifiable, Sendable {
    public let source_id: String
    public let status: String
    public let files: UInt64
    public let cache_hits: UInt64
    public let coverage: [String: UInt64]
    public var id: String { source_id }
}
public struct UsageSnapshot: Codable, Sendable {
    public let recent_activity: RecentActivity?
    public let schema_version: Int
    public let host_id: String
    public let configuration_fingerprint: String
    public let generated_at: String
    public let timezone: String
    public let complete: Bool
    public let coverage_complete: Bool
    public let rows: [UsageRow]
    public let totals: Tokens
    public let sources: [SourceStatus]
    public let sqlite_version: String?
    public static func decode(_ data: Data) throws -> UsageSnapshot {
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.schema_version == 1, snapshot.complete, snapshot.timezone == "Asia/Singapore", label(snapshot.host_id), fingerprint(snapshot.configuration_fingerprint) else {throw UsageError.invalidSnapshot}
        let instant=ISO8601DateFormatter()
        instant.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let seconds=ISO8601DateFormatter()
        guard instant.date(from:snapshot.generated_at) != nil || seconds.date(from:snapshot.generated_at) != nil else {throw UsageError.invalidSnapshot}
        guard snapshot.sources.allSatisfy({["ok","empty","partial","unmetered"].contains($0.status)}) else {throw UsageError.invalidSnapshot}
        let ids = Set(snapshot.sources.map(\.source_id))
        guard ids.count == snapshot.sources.count, ids.allSatisfy(label) else {throw UsageError.invalidSnapshot}
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.calendar=Calendar(identifier:.gregorian);formatter.timeZone=TimeZone(secondsFromGMT:8*3600);formatter.dateFormat="yyyy-MM-dd";formatter.isLenient=false
        var sum = Tokens()
        for row in snapshot.rows {
            if let hour=row.hour, !(0...23).contains(hour) || row.day == nil || row.time_basis != "event_timestamp" {throw UsageError.invalidSnapshot}
            if let role=row.execution_role, !["main","subagent"].contains(role) {throw UsageError.invalidSnapshot}
            guard ids.contains(row.source_id), label(row.model), ["codex","claude","agy","hermes","openclaw","workbuddy"].contains(row.agent),
                  row.day == nil ? ["unallocated","unallocated_interval"].contains(row.time_basis) : ["event_timestamp","aggregate_interval"].contains(row.time_basis) else {throw UsageError.invalidSnapshot}
            if let day = row.day {
                guard day.utf8.count == 10, let date=formatter.date(from:day), formatter.string(from:date)==day else {throw UsageError.invalidSnapshot}
            }
            if let kind=row.usage_kind, !["main","auxiliary","residual"].contains(kind) {throw UsageError.invalidSnapshot}
            if let backend=row.backend, !label(backend) {throw UsageError.invalidSnapshot}
            if let provider=row.provider, !label(provider) {throw UsageError.invalidSnapshot}
            let hasInterval=["aggregate_interval","unallocated_interval"].contains(row.time_basis)
            guard hasInterval == (row.interval != nil) else {throw UsageError.invalidSnapshot}
            if let bounds=row.interval {
                func date(_ text:String?) throws -> Date? {
                    guard let text else {return nil}
                    guard let value=instant.date(from:text) ?? seconds.date(from:text) else {throw UsageError.invalidSnapshot}
                    return value
                }
                let start=try date(bounds.start), end=try date(bounds.end)
                guard start != nil || end != nil else {throw UsageError.invalidSnapshot}
                if let start, let end, start > end {throw UsageError.invalidSnapshot}
                if let day=row.day {
                    guard let start, let end, formatter.string(from:start)==day, formatter.string(from:end)==day else {throw UsageError.invalidSnapshot}
                }
            }
            sum = try sum.adding(row.tokens)
        }
        guard sum == snapshot.totals else {throw UsageError.invalidSnapshot}
        try snapshot.recent_activity?.validate(snapshot:snapshot)
        return snapshot
    }
    public func selected(agent: String? = nil, model: String? = nil, start: String? = nil, end: String? = nil) -> [UsageRow] {
        rows.filter { row in
            if let agent, row.agent != agent {return false}
            if let model, row.model != model {return false}
            if start != nil || end != nil {
                guard let day=row.day else {return false}
                if let start, day < start {return false}
                if let end, day > end {return false}
            }
            return true
        }
    }
    public static func total(_ rows: [UsageRow]) throws -> Tokens { try rows.reduce(Tokens()) {try $0.adding($1.tokens)} }
}
func label(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }
}

func fingerprint(_ value:String)->Bool {value.utf8.count==64 && value.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
