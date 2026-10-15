import Foundation

public enum MenuPeriod: String, CaseIterable, Sendable {
    case today, week, month, all
    public var title: String { switch self {case .today:"今日";case .week:"近 7 天";case .month:"近 30 天";case .all:"全部"} }
    public func bounds(now:Date) -> (String?,String?) {
        guard self != .all else {return (nil,nil)}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:8*3600)!
        let days=self == .today ? 0 : self == .week ? 6 : 29
        return (Self.day(calendar.date(byAdding:.day,value:-days,to:now)!),Self.day(now))
    }
    public static func day(_ date:Date)->String {
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.calendar=Calendar(identifier:.gregorian);f.timeZone=TimeZone(secondsFromGMT:8*3600);f.dateFormat="yyyy-MM-dd";return f.string(from:date)
    }
}
public struct MenuBucket: Identifiable, Sendable {
    public let id:String
    public let value:UInt64
}
public struct MenuSummary: Sendable {
    public let tokens:Tokens?
    public let agents:[MenuBucket]
    public let models:[MenuBucket]
    public let days:[MenuBucket]
    public let unallocated:UInt64
    public init(fleet:FleetSnapshot?,snapshot:UsageSnapshot?,host:String?=nil,agent:String?=nil,period:MenuPeriod,now:Date=Date()) throws {
        let bounds=period.bounds(now:now)
        let available=fleet?.hasData(host:host) ?? (snapshot != nil && (host == nil || snapshot?.host_id==host))
        let all=fleet?.selected(host:host,agent:agent) ?? snapshot?.selected(agent:agent) ?? []
        let rows=all.filter { r in
            guard let start=bounds.0,let end=bounds.1 else {return true}
            guard let day=r.day else {return false};return day>=start && day<=end
        }
        tokens=available ? try UsageSnapshot.total(rows) : nil
        unallocated=try UsageSnapshot.total(all.filter{$0.day==nil}).total
        func grouped(_ key:(UsageRow)->String?) throws -> [MenuBucket] {
            var sums=[String:UInt64]()
            for row in rows {if let k=key(row) {let (sum,overflow)=(sums[k] ?? 0).addingReportingOverflow(try row.tokens.total);if overflow {throw UsageError.overflow};sums[k]=sum}}
            return sums.map{MenuBucket(id:$0.key,value:$0.value)}.sorted{$0.value == $1.value ? $0.id<$1.id : $0.value>$1.value}
        }
        agents=try grouped{$0.agent};models=try grouped{$0.model};days=try grouped{$0.day}.sorted{$0.id<$1.id}
    }
    public static func compact(_ value:UInt64)->String {
        for (scale,suffix) in [(1_000_000_000.0,"B"),(1_000_000.0,"M"),(1_000.0,"K")] {if Double(value)>=scale {return String(format:"%.1f%@",locale:Locale(identifier:"en_US_POSIX"),Double(value)/scale,suffix)}}
        return String(value)
    }
}
