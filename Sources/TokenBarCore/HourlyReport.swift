import Foundation

// Per-hour report (`HourlyReport` in types.ts).

public struct HourlyReportEntry: Decodable, Sendable {
    /// "YYYY-MM-DD HH:00" local-time slot.
    public let hour: String
    public let clients: [String]
    public let models: [String]
    public let input: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let reasoning: Int64
    public let total: Int64
    public let messageCount: Int
    public let turnCount: Int
    public let costEstimate: Double?
    public let messageCountComplete: Bool?
    public let cost: Double
}

public struct HourlyReport: Decodable, Sendable {
    public let entries: [HourlyReportEntry]
    public let unallocatedTokens: Int64?
    public let hourCoverageComplete: Bool?
    public let costEstimate: Double?
    public let totalCost: Double
}
