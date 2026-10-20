import Foundation
import UsageCore

struct FleetHeaderKey: Equatable {
    let revision:UUID
    let host:String
    let clients:[String]
    let year:String?
    let configuration:String?
    let available:Bool
    func canRetain(_ previous:Self?) -> Bool {
        guard let previous,available,configuration != nil else {return false}
        return previous.available && configuration==previous.configuration && host==previous.host && clients==previous.clients && year==previous.year
    }
}
struct FleetHeaderReport: Sendable, Equatable {
    let unallocated:UInt64
    let note:String
    var total:UInt64? = nil
    var cost:Double? = nil
    var costComplete=false
}

/// CPU work is actor-isolated away from SwiftUI/AppKit. The cache compares the
/// actual rows, not timestamps: same-time corrections must invalidate prices.
actor FleetPresentation {
    static let shared=FleetPresentation()
    private let catalog=try? PriceCatalog.bundled()
    private struct Scope: Hashable {
        let host:String
        let clients:[String]
        let year:String?
    }
    private struct Cached {
        let rows:[UsageRow]
        let report:FleetHeaderReport
    }
    private var headers=[Scope:Cached]()
#if DEBUG
    private(set) var headerBuildCount=0
#endif

    func clients(_ result:CollectionResult) -> [String] {
        Array(Set(rows(result).map(\.agent))).sorted()
    }
    private func rows(_ result:CollectionResult) -> [UsageRow] {
        switch result {case .fleet(let fleet):return fleet.selected();case .local(let snapshot):return snapshot.rows}
    }
    func menu(_ result:CollectionResult,mode:TrayMode,now:Date=Date()) throws -> (title:String,stale:Bool) {
        let stale:Bool,available:Bool
        switch result {
        case .fleet(let f):stale = !f.complete;available=f.hasData()
        case .local:stale=false;available=true
        }
        if mode == .hidden {return ("",stale)}
        if mode == .tokensPerMin {return ("速率 —",stale)}
        if mode == .quotaLeft {return ("额度 —",stale)}
        guard available else {return (mode == .todayCost || mode == .totalCost ? "金额 —":"—",stale)}
        let all=rows(result)
        // A date formatter is created once per update, never once per row.
        let today=MenuPeriod.day(now)
        let scoped=(mode == .todayCost || mode == .todayTokens) ? all.filter{$0.day==today}:all
        if mode == .todayCost || mode == .totalCost {
            let estimate=try catalog?.summary(scoped)
            return (estimate?.doubleValue.map{String(format:"≈$%.2f",$0)+(estimate?.complete == true ? "":"*")} ?? "金额 —",stale)
        }
        return (MenuSummary.compact(try UsageSnapshot.total(scoped).total),stale)
    }

    func header(fleet:FleetSnapshot?,local:UsageSnapshot?,host:String,clients:[String],year:String?) -> FleetHeaderReport {
        let selectedHost=host.isEmpty ? nil:host
        let available=fleet?.hasData(host:selectedHost) ?? (local != nil)
        guard available else {return FleetHeaderReport(unallocated:0,note:"尚无当前配置的可用用量")}
        let all=fleet?.selected(host:selectedHost) ?? local?.rows ?? []
        let scope=Scope(host:host,clients:Array(Set(clients)).sorted(),year:year)
        if let cached=headers[scope],cached.rows==all {return cached.report}
#if DEBUG
        headerBuildCount+=1
#endif
        let selected=Set(clients)
        let rows=all.filter{selected.contains($0.agent) && (year==nil || $0.day?.hasPrefix(year!+"-")==true)}
        let count=try? MessageCount.total(rows)
        let cost=try? catalog?.summary(rows)
        let countText=count.map {if $0.known==0 && !$0.complete {return "已计量响应/API 调用：—（计数未覆盖）"};return "已计量响应/API 调用：\($0.known.formatted())\($0.complete ? "" : "（部分来源未覆盖）")"} ?? "响应计数不可用"
        let note:String
        if let cost {
            let ratio=cost.totalTokens>0 ? Double(cost.pricedTokens)/Double(cost.totalTokens)*100:100
            note=countText+"\n目录价估算："+(cost.doubleValue.map{String(format:"≈$%.2f",$0)} ?? "—")+String(format:" · 已定价 Token %.1f%%",ratio)+"\n价格版本 "+cost.version+" · 标准短上下文/5m 缓存/峰值；不等于账单或完整对话数。"
        } else {note=countText+" · 价格目录不可用"}
        let unallocated=(try? UsageSnapshot.total(all.filter{$0.day==nil}).total) ?? 0
        let report=FleetHeaderReport(unallocated:unallocated,note:note,total:try? UsageSnapshot.total(rows).total,cost:cost?.doubleValue,costComplete:cost?.complete ?? false)
        if headers.count>=8 {headers.removeAll(keepingCapacity:true)}
        headers[scope]=Cached(rows:all,report:report)
        return report
    }
}
