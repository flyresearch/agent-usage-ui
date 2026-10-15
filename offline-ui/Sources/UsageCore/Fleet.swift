import Foundation

public struct FleetHost: Codable, Identifiable, Sendable {
    public let host_id: String
    public let state: String
    public let included: Bool
    public let last_success_at: String?
    public let last_attempt_at: String?
    public let error: String?
    public let failed_source_id: String?
    public let snapshot: UsageSnapshot?
    public var id: String {host_id}
    public var stateLabel: String {
        ["fresh":"已同步","stale":"上次成功快照","never_collected":"尚未采集","configuration_changed":"配置已变更，等待采集"][state] ?? "状态未知"
    }
}
public struct FleetSnapshot: Codable, Sendable {
    public let schema_version: Int
    public let kind: String
    public let configuration_fingerprint: String
    public let generated_at: String
    public let complete: Bool
    public let coverage_complete: Bool
    public let totals: Tokens?
    public let hosts: [FleetHost]
    public static func decode(_ data: Data) throws -> FleetSnapshot {
        let fleet=try JSONDecoder().decode(Self.self,from:data)
        let ids=Set(fleet.hosts.map(\.host_id))
        guard fleet.schema_version==1, fleet.kind=="fleet_snapshot", !fleet.hosts.isEmpty, ids.count==fleet.hosts.count, ids.allSatisfy(label),
              fleet.configuration_fingerprint.utf8.count==64, fleet.configuration_fingerprint.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}), validInstant(fleet.generated_at) else {throw UsageError.invalidSnapshot}
        var sum=Tokens();var any=false;var complete=true;var coverage=true
        for host in fleet.hosts {
            guard ["fresh","stale","never_collected","configuration_changed"].contains(host.state), host.included == ["fresh","stale"].contains(host.state) else {throw UsageError.invalidSnapshot}
            if let error=host.error, !label(error) {throw UsageError.invalidSnapshot}
            if let source=host.failed_source_id, !label(source) || host.error==nil {throw UsageError.invalidSnapshot}
            for time in [host.last_success_at,host.last_attempt_at].compactMap({$0}) {guard validInstant(time) else {throw UsageError.invalidSnapshot}}
            if let snapshot=host.snapshot {
                guard snapshot.host_id==host.host_id,host.state != "never_collected",host.last_success_at != nil else {throw UsageError.invalidSnapshot}
                _=try UsageSnapshot.decode(JSONEncoder().encode(snapshot))
                if host.included {sum=try sum.adding(snapshot.totals);any=true;coverage = coverage && snapshot.coverage_complete}
            } else {
                guard host.state=="never_collected",!host.included,host.last_success_at==nil else {throw UsageError.invalidSnapshot}
            }
            if host.state=="fresh",host.error != nil {throw UsageError.invalidSnapshot}
            complete = complete && host.state=="fresh"
            if !host.included {coverage=false}
        }
        guard fleet.totals == (any ? sum : nil), fleet.complete==complete, fleet.coverage_complete==(coverage && complete) else {throw UsageError.invalidSnapshot}
        return fleet
    }
    public func selected(host: String? = nil, agent: String? = nil, model: String? = nil, start: String? = nil, end: String? = nil) -> [UsageRow] {
        hosts.filter{$0.included && (host == nil || host == $0.host_id)}.flatMap{$0.snapshot?.selected(agent:agent,model:model,start:start,end:end) ?? []}
    }
    public func hasData(host:String? = nil)->Bool {hosts.contains{$0.included && (host == nil || host == $0.host_id)}}
}
private func validInstant(_ text:String)->Bool {
    let format=ISO8601DateFormatter();format.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
    return format.date(from:text) != nil || ISO8601DateFormatter().date(from:text) != nil
}
