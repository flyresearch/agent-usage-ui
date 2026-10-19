import Foundation

public struct ActivityBucket: Codable, Sendable {
    public let timestamp: Int64
    public let agent: String
    public let tokens: UInt64
    public let messages: MessageCount
}
public struct RecentActivity: Codable, Sendable {
    public let as_of: Int64
    public let window_seconds: UInt64
    public let coverage_complete: Bool
    public let unlocated_records: UInt64
    public let future_records: UInt64
    public let unsupported_sources: [String]
    public let buckets: [ActivityBucket]
    public func validate(snapshot: UsageSnapshot) throws {
        guard window_seconds == 600, as_of >= Int64.min+600,
              !coverage_complete || (unlocated_records==0 && future_records==0 && unsupported_sources.isEmpty),
              unsupported_sources.allSatisfy({id in snapshot.sources.contains{$0.source_id==id}}) else {throw UsageError.invalidSnapshot}
        var seen=Set<String>();var total:UInt64=0
        for bucket in buckets {
            guard bucket.timestamp>as_of-600,bucket.timestamp<=as_of,
                  ["codex","claude","agy","hermes","openclaw","workbuddy"].contains(bucket.agent),
                  seen.insert("\(bucket.timestamp)|\(bucket.agent)").inserted else {throw UsageError.invalidSnapshot}
            let (next,overflow)=total.addingReportingOverflow(bucket.tokens);guard !overflow else {throw UsageError.overflow};total=next
        }
        guard total <= (try snapshot.totals.total) else {throw UsageError.invalidSnapshot}
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard let generated=formatter.date(from:snapshot.generated_at) ?? ISO8601DateFormatter().date(from:snapshot.generated_at),
              Double(as_of)<=generated.timeIntervalSince1970 else {throw UsageError.invalidSnapshot}
    }
}
public struct ActivityClient: Identifiable, Sendable {
    public let agent: String
    public let tokens: UInt64
    public let messages: MessageCount
    public var id: String {agent}
}
public struct LiveActivityReport: Sendable {
    public let clients: [ActivityClient]
    public let missingHosts: [String]
    public let retainedHosts: [String]
    public let available: Bool
    public let complete: Bool
    public let oldestSample: Date?
    public let windowSeconds: Int
    public var rate: Double? {
        guard available else {return nil}
        return clients.reduce(0.0){$0+Double($1.tokens)}*60/Double(windowSeconds)
    }
    /// Each host's window ends at its own collection time. Freshness is bounded
    /// separately; a stale host never quietly decays into zero recent activity.
    public init(fleet: FleetSnapshot?, snapshot: UsageSnapshot?, host: String? = nil,
                windowSeconds: Int = 600, now: Date = Date()) throws {
        guard (1...600).contains(windowSeconds) else {throw UsageError.invalidSnapshot}
        var grouped=[String:(UInt64,MessageCount)]();var missing=[String]();var retained=[String]();var complete=true;var times=[Date]()
        func add(_ snapshot: UsageSnapshot, fresh: Bool) throws {
            guard let activity=snapshot.recent_activity else {missing.append(snapshot.host_id);complete=false;return}
            let sample=Date(timeIntervalSince1970:Double(activity.as_of)),age=now.timeIntervalSince(sample)
            guard age >= -5 && age <= 75 else {missing.append(snapshot.host_id);complete=false;return}
            if !fresh {retained.append(snapshot.host_id);complete=false}
            times.append(sample);complete = complete && activity.coverage_complete
            for bucket in activity.buckets where bucket.timestamp>activity.as_of-Int64(windowSeconds) {
                let old=grouped[bucket.agent] ?? (0,MessageCount(known:0,complete:true))
                let (tokens,overflow)=old.0.addingReportingOverflow(bucket.tokens)
                guard !overflow else {throw UsageError.overflow}
                grouped[bucket.agent]=(tokens,try old.1.adding(bucket.messages))
            }
        }
        if let fleet {
            for h in fleet.hosts where host == nil || h.host_id==host {
                if h.included,let s=h.snapshot {try add(s,fresh:h.state=="fresh")}
                else {missing.append(h.host_id);complete=false}
            }
        } else if let snapshot,host == nil || host==snapshot.host_id {try add(snapshot,fresh:true)}
        self.clients=grouped.keys.sorted().map {ActivityClient(agent:$0,tokens:grouped[$0]!.0,messages:grouped[$0]!.1)}
        self.missingHosts=missing;self.retainedHosts=retained;self.available = !times.isEmpty
        self.complete = !times.isEmpty && complete;self.oldestSample=times.min();self.windowSeconds=windowSeconds
    }
}
