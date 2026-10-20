import Foundation
import Darwin

public struct QuotaObservation: Codable, Identifiable, Sendable, Equatable {
    public var id:String
    public var provider:String
    public var window:String
    public var title:String
    public var time:Date
    public var used:Double
    public var reset:Date?
    public var duration:Int?
    public var segment:String
    public var continuous:Bool
}
public struct QuotaTrend: Sendable {
    public let percentagePointsPerHour:Double
    public let exhaustedAt:Date?
    public let sampleCount:Int
}
/// Single-owner value store. Account comparison keys live only in memory; a
/// restart or failure starts a new segment. Never infer continuity from balance.
public struct NativeQuotaHistory: Sendable {
    public private(set) var points:[QuotaObservation]=[]
    private var scopes=[String:String]()
    private var segments=[String:String]()
    public init() {}
    public init(data:Data,now:Date=Date()) throws {
        guard data.count<=16*1024*1024 else {throw NativeQuotaError.invalidResponse}
        let value=try JSONDecoder().decode(Envelope.self,from:data)
        guard value.version==1,value.points.count<=30000 else {throw NativeQuotaError.invalidResponse}
        var ids=Set<String>()
        for p in value.points {
            guard ids.insert(p.id).inserted,UUID(uuidString:p.id) != nil,UUID(uuidString:p.segment) != nil,
                  ["codex","agy","claude"].contains(p.provider),!p.window.isEmpty,p.window.count<=128,!p.title.isEmpty,p.title.count<=128,
                  p.time.timeIntervalSince1970.isFinite,p.time<=now.addingTimeInterval(5),
                  p.used.isFinite,(0...100).contains(p.used),
                  p.reset.map({$0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970>0 && $0.timeIntervalSince1970<253402300800}) ?? true,
                  p.duration.map({$0>0 && $0<=525600}) ?? true else {throw NativeQuotaError.invalidResponse}
        }
        points=value.points.sorted{$0.time<$1.time};prune(now:now)
    }
    private struct Envelope:Codable {var version:Int;var points:[QuotaObservation]}
    public func encoded() throws -> Data {try JSONEncoder().encode(Envelope(version:1,points:points))}
    public mutating func breakContinuity(_ provider:NativeQuotaProvider) {
        scopes[provider.rawValue]=nil
        segments=segments.filter{!$0.key.hasPrefix(provider.rawValue+"|")}
    }
    private mutating func prune(now:Date) {
        points.removeAll{$0.time<now.addingTimeInterval(-7*86400)}
        for provider in ["codex","agy","claude"] {
            let ids=Set(points.filter{$0.provider==provider}.dropLast(10000).map(\.id))
            points.removeAll{ids.contains($0.id)}
        }
    }
    public mutating func record(_ snapshot:NativeQuotaSnapshot,provider:NativeQuotaProvider,now:Date=Date()) {
        guard snapshot.fresh(at:now) else {breakContinuity(provider);return}
        let source=provider.rawValue
        let scope=snapshot.continuityKey
        if scopes[source] != scope {breakContinuity(provider)}
        scopes[source]=scope
        let liveKeys=Set(snapshot.windows.map{source+"|"+$0.id})
        segments=segments.filter{!$0.key.hasPrefix(source+"|") || liveKeys.contains($0.key)}
        for window in snapshot.windows {
            let key=source+"|"+window.id
            let previous=points.last{$0.provider==source && $0.window==window.id}
            // Re-reading Claude's same callback must not manufacture samples.
            if let previous,previous.time>=snapshot.capturedAt {
                if previous.time>snapshot.capturedAt || previous.used != window.usedPercent || previous.reset != window.resetsAt {segments[key]=nil}
                continue
            }
            let continuous=scope != nil && window.resetsAt != nil && window.durationMinutes != nil
            var segment=segments[key]
            if let previous {
                let gap=snapshot.capturedAt.timeIntervalSince(previous.time)
                if gap>300 || previous.reset != window.resetsAt || previous.duration != window.durationMinutes || window.usedPercent<previous.used {segment=nil}
            }
            if !continuous {segment=nil}
            let current=segment ?? UUID().uuidString
            segments[key]=current
            points.append(QuotaObservation(id:UUID().uuidString,provider:source,window:window.id,title:window.title,time:snapshot.capturedAt,used:window.usedPercent,reset:window.resetsAt,duration:window.durationMinutes,segment:current,continuous:continuous))
        }
        prune(now:now)
    }
    public func observations(_ provider:NativeQuotaProvider) -> [QuotaObservation] {points.filter{$0.provider==provider.rawValue}}
    public static func trend(_ points:[QuotaObservation],now:Date=Date()) -> QuotaTrend? {
        guard let last=points.last,last.continuous,now.timeIntervalSince(last.time)>=0,now.timeIntervalSince(last.time)<=90,
              let reset=last.reset,reset>now,let duration=last.duration,duration>0 else {return nil}
        let sample=points.filter{$0.segment==last.segment && $0.window==last.window && $0.provider==last.provider && $0.time>=last.time.addingTimeInterval(-1800)}
        guard sample.count>=3,let first=sample.first,last.time.timeIntervalSince(first.time)>=300 else {return nil}
        for (a,b) in zip(sample,sample.dropFirst()) {
            guard b.time>a.time,b.time.timeIntervalSince(a.time)<=300,b.used>=a.used,b.reset==a.reset,b.duration==a.duration else {return nil}
        }
        let rate=(last.used-first.used)*3600/last.time.timeIntervalSince(first.time)
        guard rate.isFinite,rate>=0 else {return nil}
        let predicted=rate>0 ? last.time.addingTimeInterval((100-last.used)*3600/rate):reset
        return QuotaTrend(percentagePointsPerHour:rate,exhaustedAt:predicted<reset ? predicted:nil,sampleCount:sample.count)
    }
}

/// One writer per private archive; a second app instance cannot overwrite it.
public final class NativeQuotaArchive {
    private let lock:FileHandle
    private let path:URL
    public private(set) var history:NativeQuotaHistory
    public init(directory:URL,now:Date=Date()) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        path=directory.appendingPathComponent("quota-history.json")
        let fd=Darwin.open(directory.appendingPathComponent("quota-history.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else {throw NativeQuotaError.requestFailed}
        lock=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else {try? lock.close();throw NativeQuotaError.requestFailed}
        if FileManager.default.fileExists(atPath:path.path) {
            let file=try FileHandle(forReadingFrom:path);defer{try? file.close()}
            history=try NativeQuotaHistory(data:file.read(upToCount:16*1024*1024+1) ?? Data(),now:now)
        } else {history=NativeQuotaHistory()}
    }
    public func breakContinuity(_ provider:NativeQuotaProvider) {history.breakContinuity(provider)}
    public func record(_ snapshot:NativeQuotaSnapshot,provider:NativeQuotaProvider,now:Date=Date()) throws {
        var next=history;next.record(snapshot,provider:provider,now:now)
        if next.points.count != history.points.count || next.points.last?.id != history.points.last?.id {
            try LocalCollector.publish(next.encoded(),to:path)
        }
        history=next
    }
}
