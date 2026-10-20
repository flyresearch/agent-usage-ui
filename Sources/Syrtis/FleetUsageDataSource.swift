import Foundation
import TokenBarCore
import UsageCore

/// Explicit offline build/runtime lane. The original Syrtis UI remains the consumer.
enum FleetMode {
    static let enabled = AgentUsageProduct.enabled && !CommandLine.arguments.contains(where:{["--demo","--selftest","--icon-gallery","--smoke"].contains($0)}) && AgentUsageMode.current == .fleet
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
    private var lastAttempt=Date.distantPast
    private var quotaArchive:NativeQuotaArchive?
    private var quotaArchiveLastAttempt:TimeInterval = -1000
    private var quotaArchiveFailed=false
    private var quotaFlights=[NativeQuotaProvider:Task<NativeQuotaSnapshot,Error>]()
    private var quotaKeys=[NativeQuotaProvider:String]()
    private var quotaGenerations=[NativeQuotaProvider:UInt64]()
    private var quotaAttempts=[NativeQuotaProvider:TimeInterval]()
    private func settings() throws -> CollectorSettings {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AgentUsageOffline")
        let stored=try JSONDecoder().decode(CollectorSettings.self,from:Data(contentsOf:root.appendingPathComponent("connection.json")))
        return LocalCollector.reboundSettings(stored,currentExecutable:Bundle.main.url(forAuxiliaryExecutable:"agent-usage"))
    }
    /// Native views must not stop an explicitly configured fleet schedule.
    /// No report subprocess is started merely to wait for the next due time.
    func backgroundRefreshIfNeeded() async {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("AgentUsageOffline/connection.json").path) else {return}
        do {
            let config=try settings()
            guard try config.automaticCollectionDue(since:lastAttempt) else {return}
            _=try await result()
        } catch {
            await MainActor.run {FleetUIState.shared.error="后台采集失败，保留上次成功结果"}
        }
    }

    func result(force:Bool=false) async throws -> CollectionResult {
        if let flight {return try await flight.value}
        // Always revalidate the current configuration through the collector.
        let config=try settings()
        let interval=try config.collectionInterval()
        let sync=force || (config.autoRefresh != false && Date().timeIntervalSince(lastAttempt)>=interval)
        if sync {lastAttempt=Date()}
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
                if case UsageError.configurationChanged=error {FleetUIState.shared.fleet=nil;FleetUIState.shared.local=nil;FleetUIState.shared.revision=UUID()}
            }
            throw error
        }
        last=result
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
    func agentUsage() async throws -> AgentUsagePayload {
        await refreshAllQuotas()
        let values=await MainActor.run {NativeQuotaProvider.allCases.map { provider in
            let state=FleetUIState.shared.quotaState(provider)
            return (provider,state.quotaEnabled,state.quota)
        }}
        return try projectQuotas(values)
    }
    func projectQuotas(_ values:[(NativeQuotaProvider,Bool,NativeQuotaSnapshot?)],now:Date=Date()) throws -> AgentUsagePayload {
        let formatter=ISO8601DateFormatter()
        var agents=[[String:Any]]()
        for (provider,enabled,snapshot) in values {
            guard enabled else {continue}
            var entry:[String:Any]=["clientId":provider.rawValue,"source":provider == .claude ? "native-statusline":"native-cli","updatedAt":formatter.string(from:snapshot?.capturedAt ?? now),"windows":[] as [[String:Any]]]
            if let snapshot,snapshot.remaining(at:now) != nil {
                entry["windows"]=snapshot.windows.map { window -> [String:Any] in
                    var value:[String:Any]=["cardId":window.id,"label":window.title,"usedPercent":window.usedPercent,"remainingPercent":window.remainingPercent]
                    value["resetsAt"]=window.resetsAt.map{formatter.string(from:$0)}
                    value["windowMinutes"]=window.durationMinutes
                    var pace:[String:Any]=["state":"unavailable","windowKey":window.id,"completeCycles":0,"reason":"accountScope"]
                    if let minutes=window.durationMinutes {
                        pace["durationSeconds"]=minutes*60
                        pace["durationSource"]=provider == .claude ? "contract":"provider"
                    }
                    value["paceStatus"]=pace
                    return value
                }
            } else {entry["error"]="quota_unavailable"}
            agents.append(entry)
        }
        return try decode(["generatedAt":formatter.string(from:now),"agents":agents],as:AgentUsagePayload.self)
    }
    func projectActivity(_ result:CollectionResult,windowSecs:Int,now:Date=Date()) throws -> LiveActivityReport {
        let host=selectedHost()
        switch result {
        case .local(let s):return try LiveActivityReport(fleet:nil,snapshot:s,windowSeconds:windowSecs,now:now)
        case .fleet(let f):return try LiveActivityReport(fleet:f,snapshot:nil,host:host,windowSeconds:windowSecs,now:now)
        }
    }
    func usageTrace(windowSecs:Int64) async throws -> [TraceBucket] {
        let config=try settings(), scope=selectedHost()
        await MainActor.run {FleetUIState.shared.liveEnabled = config.liveMetrics == true}
        guard config.liveMetrics == true else {
            await MainActor.run {FleetUIState.shared.activity=nil}
            throw FleetSourceError.unsupported
        }
        let report:LiveActivityReport
        let buckets:[TraceBucket]
        do {
            report=try projectActivity(await result(),windowSecs:Int(windowSecs))
            guard try settings().liveMetrics == true,selectedHost()==scope else {throw FleetSourceError.unavailable}
            buckets=try report.clients.map {row in
                guard let messages=Int(exactly:row.messages.known) else {throw FleetSourceError.outOfRange}
                return TraceBucket(client:row.agent,agent:"已知调用",model:"all-models",tokens:try int(row.tokens),messages:messages,
                                   tokensPerMin:Double(row.tokens)*60/Double(windowSecs))
            }
        } catch {
            await MainActor.run {FleetUIState.shared.activity=nil}
            throw error
        }
        let published=await MainActor.run {
            let current=UserDefaults.standard.string(forKey:"agentusage.selectedHost").flatMap{$0.isEmpty ? nil:$0}
            guard current==scope else {return false}
            FleetUIState.shared.activity=report
            return true
        }
        guard published,report.available else {throw FleetSourceError.unavailable}
        return buckets
    }
    func tokensPerMin() async throws -> Double {try await usageTrace(windowSecs:600).reduce(0){$0+$1.tokensPerMin}}
    func refreshAllQuotas(force:Bool=false) async {
        async let codex:Void=refreshQuota(provider:.codex,force:force)
        async let agy:Void=refreshQuota(provider:.agy,force:force)
        async let claude:Void=refreshQuota(provider:.claude,force:force)
        _=await (codex,agy,claude)
    }
    private func loadQuotaHistory() {
        let now=ProcessInfo.processInfo.systemUptime
        guard quotaArchive==nil,now-quotaArchiveLastAttempt>=10 else {return}
        quotaArchiveLastAttempt=now
        do {
            let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AgentUsageOffline/quota-history")
            quotaArchive=try NativeQuotaArchive(directory:directory)
            quotaArchiveFailed=false
        } catch {quotaArchiveFailed=true}
    }
    func refreshQuota(provider:NativeQuotaProvider = .codex,force:Bool=false) async {
        loadQuotaHistory()
        let saved=quotaArchive?.history.observations(provider) ?? []
        let historyFailed=quotaArchiveFailed
        await MainActor.run {
            let state=FleetUIState.shared.quotaState(provider)
            if state.history.isEmpty {state.history=saved}
            state.historyMessage=historyFailed ? "本地历史不可用（文件损坏、不可写或另一实例正在使用）；当前额度仍可查询。":nil
        }
        let config:CollectorSettings
        do {config=try settings()} catch {
            quotaArchive?.breakContinuity(provider)
            await MainActor.run {FleetUIState.shared.quotaState(provider).quota=nil;FleetUIState.shared.quotaState(provider).quotaMessage="无法读取额度配置"}
            return
        }
        let enabled=config.quotaEnabled(provider), executable=config.quotaExecutable(provider)
        let key=enabled ? "enabled|"+executable : "disabled"
        let changed=key != quotaKeys[provider]
        if changed {
            quotaArchive?.breakContinuity(provider)
            quotaFlights[provider]?.cancel();quotaFlights[provider]=nil;quotaKeys[provider]=key;quotaAttempts[provider] = -1000;quotaGenerations[provider,default:0] &+= 1
        }
        let generation=quotaGenerations[provider,default:0]
        await MainActor.run {
            let state=FleetUIState.shared.quotaState(provider)
            guard generation>=state.quotaGeneration else {return}
            state.quotaGeneration=generation;state.quotaEnabled=enabled
            if changed {state.quota=nil;state.quotaMessage=nil;state.quotaLoading=false}
        }
        guard generation==quotaGenerations[provider,default:0],enabled else {return}
        if let flight=quotaFlights[provider] {_=try? await flight.value;return}
        let now=ProcessInfo.processInfo.systemUptime
        guard now-(quotaAttempts[provider] ?? -1000) >= (provider == .claude ? (force ? 1:10):(force ? 10:60)) else {return}
        quotaAttempts[provider]=now
        await MainActor.run {
            let state=FleetUIState.shared.quotaState(provider)
            guard state.quotaGeneration==generation else {return}
            state.quotaMessage=nil;state.quotaLoading=true
        }
        guard generation==quotaGenerations[provider,default:0] else {return}
        let task=Task.detached {
            switch provider {
            case .codex:return try CodexQuota.fetch(executable:executable)
            case .agy:return try AgyQuota.fetch(executable:executable)
            case .claude:return try ClaudeQuota.fetch(path:executable)
            }
        }
        quotaFlights[provider]=task
        do {
            let value=try await task.value
            let current=try settings()
            if quotaGenerations[provider,default:0]==generation,current.quotaEnabled(provider),current.quotaExecutable(provider)==executable {
                var historyMessage:String?
                do {try quotaArchive?.record(value,provider:provider)}
                catch {quotaArchive?.breakContinuity(provider);historyMessage="历史保存失败；当前额度仍可查看。"}
                let observations=quotaArchive?.history.observations(provider) ?? []
                let notice=historyMessage
                await MainActor.run {
                    let state=FleetUIState.shared.quotaState(provider)
                    if state.quotaGeneration==generation {
                        state.quota=value;state.history=observations
                        if let notice {state.historyMessage=notice}
                    }
                }
            }
        } catch {
            guard quotaGenerations[provider,default:0]==generation else {return}
            quotaArchive?.breakContinuity(provider)
            let message:String
            switch error {
            case NativeQuotaError.missingSample:message="等待 Claude Code 会话提供额度；需在订阅会话首次响应后获取"
            case NativeQuotaError.staleSample:message="Claude 会话额度样本已过期；等待新的会话观测"
            case NativeQuotaError.notLoggedIn:message="尚未登录，请先在对应原生 CLI 中登录"
            case NativeQuotaError.unsupportedAccount:message="当前账号未提供可读取的额度窗口"
            case NativeQuotaError.timedOut:message="额度查询超时，请稍后重试"
            case NativeQuotaError.unsupportedVersion:message="CLI 版本不支持安全的只读额度查询，请升级后重试"
            case NativeQuotaError.launchFailed:message="无法启动原生 CLI，请检查程序路径"
            default:message=provider == .claude ? "无法读取 Claude 额度快照，请检查状态栏桥接配置":"暂时无法获取额度，请稍后重试或检查原生 CLI 登录状态"
            }
            await MainActor.run {
                let state=FleetUIState.shared.quotaState(provider)
                if state.quotaGeneration==generation {state.quota=nil;state.quotaMessage=message}
            }
        }
        if quotaGenerations[provider,default:0]==generation {
            quotaFlights[provider]=nil
            await MainActor.run {if FleetUIState.shared.quotaState(provider).quotaGeneration==generation {FleetUIState.shared.quotaState(provider).quotaLoading=false}}
        }
    }
}
