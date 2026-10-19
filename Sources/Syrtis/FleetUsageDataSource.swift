import Foundation
import TokenBarCore
import UsageCore

/// Explicit offline build/runtime lane. The original Syrtis UI remains the consumer.
enum FleetMode {
    static let enabled = Bundle.main.object(forInfoDictionaryKey:"AgentUsageOffline") as? Bool == true || CommandLine.arguments.contains("--fleet-offline")
}

enum FleetSourceError: Error {case unavailable, unsupported, outOfRange}

actor FleetUsageDataSource: UsageDataSource {
    static let shared=FleetUsageDataSource()
    nonisolated let allowsQuotaCachePersistence=false
    private var flight:Task<CollectionResult,Error>?
    private var last:CollectionResult?
    private let pricing = try? PriceCatalog.bundled()
    private let selectedHost:@Sendable () -> String?
    init(selectedHost:@escaping @Sendable () -> String? = {UserDefaults.standard.string(forKey:"agentusage.selectedHost").flatMap{$0.isEmpty ? nil:$0}}) {self.selectedHost=selectedHost}
    private var lastSync=Date.distantPast
    private func settings() throws -> CollectorSettings {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AgentUsageOffline")
        let stored=try JSONDecoder().decode(CollectorSettings.self,from:Data(contentsOf:root.appendingPathComponent("connection.json")))
        return LocalCollector.reboundSettings(stored,currentExecutable:Bundle.main.url(forAuxiliaryExecutable:"agent-usage"))
    }
    func result(force:Bool=false) async throws -> CollectionResult {
        if let flight {return try await flight.value}
        // Always revalidate the current configuration through the collector.
        let config=try settings()
        let sync=force || (config.autoRefresh != false && Date().timeIntervalSince(lastSync)>=300)
        let task=Task.detached {try sync ? LocalCollector.refreshResult(config) : LocalCollector.restoreResult(config)}
        flight=task
        defer {flight=nil}
        let result:CollectionResult
        do {
            result=try await task.value
            let current=try settings()
            guard current.executable==config.executable,current.configuration==config.configuration,current.stateDirectory==config.stateDirectory,current.fleetMode==config.fleetMode else {throw UsageError.configurationChanged}
        } catch {
            await MainActor.run {
                FleetUIState.shared.error="采集或配置读取失败，无法确认当前状态"
                if case UsageError.configurationChanged=error {FleetUIState.shared.fleet=nil;FleetUIState.shared.local=nil}
            }
            throw error
        }
        last=result;if sync {lastSync=Date()}
        await MainActor.run {FleetUIState.shared.accept(result)}
        return result
    }
    private func rows(_ result:CollectionResult,year:String?) throws -> [UsageRow] {
        let rows:[UsageRow]
        switch result {
        case .local(let s):rows=s.rows
        case .fleet(let f):let host=selectedHost();guard f.hasData(host:host) else {throw FleetSourceError.unavailable};rows=f.selected(host:host)
        }
        return rows.filter {year==nil || $0.day?.hasPrefix(year!+"-")==true}
    }
    private func int(_ n:UInt64) throws -> Int64 {guard let n=Int64(exactly:n) else {throw FleetSourceError.outOfRange};return n}
    private func tokens(_ t:Tokens) throws -> [String:Int64] {
        _=try int(t.total)
        return try ["input":int(t.input),"output":int(t.output),"cacheRead":int(t.cache_read),"cacheWrite":int(t.cache_write),"reasoning":int(t.reasoning)]
    }
    private func decode<T:Decodable>(_ value:Any,as:T.Type) throws -> T {try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:value))}
    func graph(year:String?,priority:TaskPriority) async throws -> UsagePayload {try projectGraph(await result(),year:year)}
    func refreshGraph(year:String?,priority:TaskPriority) async throws -> UsagePayload {try projectGraph(await result(force:true),year:year)}
    func projectGraph(_ result:CollectionResult,year:String?) throws -> UsagePayload {
        let all=try rows(result,year:nil);let selected=try rows(result,year:year)
        _=try messageCount(selected)
        let dated=selected.filter{$0.day != nil};let groups=Dictionary(grouping:dated,by:{$0.day!})
        let maximum=try groups.values.map {try UsageSnapshot.total($0).total}.max() ?? 0
        var contributions=[[String:Any]]()
        for day in groups.keys.sorted() {
            let rs=groups[day]!;let sum=try UsageSnapshot.total(rs);let total=try int(sum.total)
            // Hour/role rows share a daily client/model identity. Reaggregate
            // before projecting into the original daily UI, which expects one entry.
            let clientGroups=Dictionary(grouping:rs) { $0.agent+"|"+$0.model+"|"+($0.provider ?? "unknown") }
            let clients=try clientGroups.keys.sorted().map { key -> [String:Any] in
                let rows=clientGroups[key]!, first=rows[0]
                return ["client":first.agent,"modelId":first.model,"providerId":first.provider ?? "unknown","tokens":try tokens(UsageSnapshot.total(rows)),"cost":try cost(rows),"messages":try messageCount(rows)]
            }
            contributions.append(["date":day,"totals":["tokens":total,"cost":try cost(rs),"messages":try messageCount(rs)],"intensity":total>0 ? min(4,max(1,Int(ceil(Double(total)/Double(max(1,maximum))*4)))):0,"tokenBreakdown":try tokens(sum),"clients":clients])
        }
        let today=MenuPeriod.day(Date());let dates=groups.keys.sorted();let start=dates.first ?? today;let end=dates.last ?? today
        var years=[[String:Any]]()
        for y in Set(all.compactMap{$0.day.map{String($0.prefix(4))}}).sorted() {
            let rs=all.filter{$0.day?.hasPrefix(y+"-")==true};let ds=rs.compactMap(\.day).sorted()
            years.append(["year":y,"totalTokens":try int(UsageSnapshot.total(rs).total),"totalCost":try cost(rs),"range":["start":ds.first!,"end":ds.last!]])
        }
        let total=try int(UsageSnapshot.total(selected).total)
        let dailyCosts=try groups.values.map {try cost($0)}
        let datedCost=try cost(dated)
        return try decode(["meta":["generatedAt":ISO8601DateFormatter().string(from:Date()),"version":"fleet-v1","dateRange":["start":start,"end":end]],"summary":["totalTokens":total,"totalCost":try cost(selected),"totalDays":dates.count,"activeDays":dates.count,"averagePerDay":dates.isEmpty ? 0:datedCost/Double(dates.count),"maxCostInSingleDay":dailyCosts.max() ?? 0,"clients":Set(selected.map(\.agent)).sorted(),"models":Set(selected.map(\.model)).sorted()],"years":years,"contributions":contributions],as:UsagePayload.self)
    }
    func modelReport(year:String?,priority:TaskPriority) async throws -> ModelReport {
        let result=try await result()
        return try projectModels(result,year:year)
    }
    func projectModels(_ result:CollectionResult,year:String?) throws -> ModelReport {
        let rs=try rows(result,year:year);let sum=try UsageSnapshot.total(rs)
        let groups=Dictionary(grouping:rs,by:{$0.agent+"|"+$0.model+"|"+($0.provider ?? "unknown")})
        let entries=try groups.keys.sorted().map {key -> [String:Any] in
            let rows=groups[key]!;let first=rows[0];let t=try UsageSnapshot.total(rows)
            var v=try tokens(t).mapValues{$0 as Any};v["client"]=first.agent;v["model"]=first.model;v["provider"]=first.provider ?? "unknown";v["total"]=try int(t.total);v["messageCount"]=try messageCount(rows);v["cost"]=try cost(rows);v["costEstimate"]=try pricing?.summary(rows).doubleValue;return v
        }
        return try decode(["entries":entries,"totalInput":int(sum.input),"totalOutput":int(sum.output),"totalCacheRead":int(sum.cache_read),"totalCacheWrite":int(sum.cache_write),"totalMessages":try messageCount(rs),"totalCost":try cost(rs)],as:ModelReport.self)
    }
    private func messageCount(_ rows:[UsageRow]) throws -> Int {
        guard let n=Int(exactly:try MessageCount.total(rows).known) else {throw FleetSourceError.outOfRange};return n
    }
    private func cost(_ rows:[UsageRow]) throws -> Double {
        // Legacy Syrtis DTOs require a number. The views mark estimates and
        // show pricing coverage; unknown per-model estimates remain absent.
        let value=try pricing?.summary(rows).doubleValue ?? 0
        guard value.isFinite else {throw FleetSourceError.outOfRange};return value
    }
    private func scopedRows(_ result:CollectionResult, year:String?, clients:[String]?) throws -> [UsageRow] {
        try rows(result,year:year).filter { row in clients.map { $0.contains(row.agent) } ?? true }
    }
    func projectHourly(_ result:CollectionResult, year:String?, clients:[String]?) throws -> HourlyReport {
        let rs = try scopedRows(result,year:year,clients:clients)
        _ = try int(UsageSnapshot.total(rs).total)
        let allocated = rs.filter { $0.day != nil && $0.hour != nil }
        let groups = Dictionary(grouping:allocated) { $0.day! + String(format:" %02d:00",$0.hour!) }
        let entries = try groups.keys.sorted().map { hour -> [String:Any] in
            let rows=groups[hour]!, t=try UsageSnapshot.total(rows), count=try MessageCount.total(rows)
            var v=try tokens(t).mapValues { $0 as Any }
            v["hour"]=hour;v["clients"]=Set(rows.map(\.agent)).sorted();v["models"]=Set(rows.map(\.model)).sorted()
            v["total"]=try int(t.total);v["messageCount"]=try messageCount(rows);v["messageCountComplete"]=count.complete
            // DTO compatibility only: the offline view never presents this as a known turn count.
            v["turnCount"]=0;v["cost"]=try cost(rows);v["costEstimate"]=try pricing?.summary(rows).doubleValue
            return v
        }
        return try decode(["entries":entries,"totalCost":try cost(allocated),
            "costEstimate":try pricing?.summary(allocated).doubleValue as Any? ?? NSNull(),
            "unallocatedTokens":int(UsageSnapshot.total(rs.filter{$0.hour == nil}).total),
            "hourCoverageComplete":allocated.count == rs.count],as:HourlyReport.self)
    }
    func projectAgents(_ result:CollectionResult, year:String?, clients:[String]?) throws -> AgentsReport {
        let rs=try scopedRows(result,year:year,clients:clients)
        _ = try int(UsageSnapshot.total(rs).total)
        let groups=Dictionary(grouping:rs) { $0.execution_role ?? "unknown" }
        let entries=try groups.keys.sorted().map { role -> [String:Any] in
            let rows=groups[role]!,t=try UsageSnapshot.total(rows),count=try MessageCount.total(rows)
            var v=try tokens(t).mapValues { $0 as Any }
            v["agent"]=role;v["clients"]=Set(rows.map(\.agent)).sorted();v["total"]=try int(t.total)
            v["messages"]=try messageCount(rows);v["messageCountComplete"]=count.complete
            v["cost"]=try cost(rows);v["costEstimate"]=try pricing?.summary(rows).doubleValue
            return v
        }
        return try decode(["entries":entries,"totalCost":try cost(rs),"totalMessages":try messageCount(rs),
            "costEstimate":try pricing?.summary(rs).doubleValue as Any? ?? NSNull(),
            "unclassifiedTokens":int(UsageSnapshot.total(rs.filter{$0.execution_role == nil}).total)],as:AgentsReport.self)
    }
    func hourlyReport(year:String?,clients:[String]?,priority:TaskPriority) async throws -> HourlyReport {
        try projectHourly(await result(),year:year,clients:clients)
    }
    func agentsReport(year:String?,clients:[String]?,priority:TaskPriority) async throws -> AgentsReport {
        try projectAgents(await result(),year:year,clients:clients)
    }
    func agentUsage() async throws -> AgentUsagePayload {throw FleetSourceError.unsupported}
    func usageTrace(windowSecs:Int64) async throws -> [TraceBucket] {throw FleetSourceError.unsupported}
    func tokensPerMin() async throws -> Double {throw FleetSourceError.unsupported}
}
