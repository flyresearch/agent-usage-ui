import AppKit
import SwiftUI
import UsageCore

@main struct AgentUsageApp: App {
    @StateObject private var store=DashboardStore()
    var body: some Scene {
        WindowGroup("Agent Usage",id:"dashboard") {DashboardView(store:store).frame(minWidth:1080,minHeight:720)}.defaultSize(width:1260,height:850)
        MenuBarExtra { UsageMenu(store:store) } label: {
            Label(store.menuBarTitle,systemImage:store.stale || store.failure != nil ? "exclamationmark.triangle" : "chart.bar.xaxis")
        }.menuBarExtraStyle(.window)
    }
}
@MainActor final class DashboardStore: ObservableObject {
    @Published var menuPeriod=MenuPeriod.today
    @Published var menuAgent="all"
    @Published var menuHost="all"
    @Published var menuPage="概览"
    var menuBarTitle:String {
        guard let summary=try? MenuSummary(fleet:fleet,snapshot:snapshot,period:.today),let tokens=summary.tokens,let total=try? tokens.total else {return "今日 —"}
        return "今日 " + MenuSummary.compact(total)
    }
    @Published var page="Overview"
    @Published var agent="all"
    @Published var host="all"
    @Published var model="all"
    @Published var dateRange=false
    @Published var startDate=Date().addingTimeInterval(-29*86400)
    @Published var endDate=Date()
    @Published var settingsOpen=false
    @Published var draft=CollectorSettings(executable:"",configuration:"",stateDirectory:"")
    @Published var snapshot:UsageSnapshot?
    @Published var fleet:FleetSnapshot?
    @Published var busy=false
    @Published var stale=false
    @Published var failure:String?
    @Published var localFailedSource:String?
    @Published var settings:CollectorSettings
    private let settingsURL:URL
    private var generation=UUID()
    private var timer:Task<Void,Never>?
    private var lastRefresh=Date.distantPast
    init() {
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AgentUsageOffline",isDirectory:true)
        settingsURL=support.appendingPathComponent("connection.json")
        settings=(try? JSONDecoder().decode(CollectorSettings.self,from:Data(contentsOf:settingsURL))) ?? CollectorSettings(executable:Bundle.main.url(forAuxiliaryExecutable:"agent-usage")?.path ?? "",configuration:"",stateDirectory:support.appendingPathComponent("state").path)
        restore()
        timer=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(60))} catch {return}
                guard let self else {return}
                if !self.busy && !self.settingsOpen {
                    if self.settings.autoRefresh != false && Date().timeIntervalSince(self.lastRefresh)>=300 {self.refresh()}
                    else if self.settings.fleetMode == true {self.restore()}
                }
            }
        }
    }
    var allRows:[UsageRow] {fleet?.selected(host:host == "all" ? nil : host) ?? snapshot?.rows ?? []}
    var hasResult:Bool {fleet != nil || snapshot != nil}
    var hasData:Bool {fleet?.hasData(host:host == "all" ? nil : host) ?? (snapshot != nil)}
    var generatedAt:String {fleet?.generated_at ?? snapshot?.generated_at ?? ""}
    var coverageComplete:Bool {fleet?.coverage_complete ?? snapshot?.coverage_complete ?? false}
    var heading:String {fleet.map{"\($0.hosts.count) 台机器 · 各机独立采集时间"} ?? snapshot?.host_id ?? "连接你的采集器，开始查看用量"}
    var selectedHosts:[FleetHost] {fleet?.hosts.filter{host == "all" || $0.host_id==host} ?? []}
    var selectedRows:[UsageRow] {
        let start=dateRange ? day(startDate) : nil;let end=dateRange ? day(endDate) : nil
        if let fleet {return fleet.selected(host:host=="all" ? nil : host,agent:agent=="all" ? nil : agent,model:model=="all" ? nil : model,start:start,end:end)}
        return snapshot?.selected(agent:agent=="all" ? nil : agent,model:model=="all" ? nil : model,start:start,end:end) ?? []
    }
    var unallocated:UInt64 { (try? UsageSnapshot.total(allRows.filter{$0.day==nil && (agent=="all" || $0.agent==agent) && (model=="all" || $0.model==model)}).total) ?? 0 }
    var invalidDateRange:Bool {dateRange && day(startDate)>day(endDate)}
    private func day(_ value:Date)->String {let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(identifier:"Asia/Singapore");f.dateFormat="yyyy-MM-dd";return f.string(from:value)}
    func beginSettings() {draft=settings;settingsOpen=true}
    func saveSettings()->Bool {
        guard !busy,draft.executable.hasPrefix("/"),draft.configuration.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:draft.executable) else {failure="请选择有效的采集器和配置";return false}
        draft.stateDirectory=settings.stateDirectory
        do {
            try FileManager.default.createDirectory(at:settingsURL.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try FileManager.default.createDirectory(atPath:settings.stateDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONEncoder().encode(draft).write(to:settingsURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:settingsURL.path)
            settings=draft;generation=UUID();snapshot=nil;fleet=nil;failure=nil;localFailedSource=nil;stale=false;agent="all";host="all";model="all"
            return true
        } catch {failure="无法保存本地设置";return false}
    }
    private func apply(_ result:CollectionResult,restored:Bool) {
        switch result {
        case .local(let value):snapshot=value;fleet=nil;stale=restored
        case .fleet(let value):fleet=value;snapshot=nil;stale = !value.complete
        }
        if menuHost != "all", !(fleet?.hosts.contains{$0.host_id==menuHost} ?? false) {menuHost="all"}
        if host != "all", !(fleet?.hosts.contains{$0.host_id==host} ?? false) {host="all"}
        if agent != "all", !allRows.contains(where:{$0.agent==agent}) {agent="all"}
        if model != "all", !allRows.contains(where:{$0.model==model}) {model="all"}
    }
    func restore() {
        guard !busy,!settings.executable.isEmpty,!settings.configuration.isEmpty else {return}
        busy=true;let current=settings;let token=generation
        Task {
            do {let result=try await Task.detached {try LocalCollector.restoreResult(current)}.value
                if token==generation {apply(result,restored:true)}
            } catch UsageError.configurationChanged {snapshot=nil;fleet=nil;stale=false;failure="配置已变更或不可读取，请刷新或检查配置"}
            catch {stale=hasResult;failure=hasResult ? "快照状态无法更新，请刷新或检查配置" : "尚无可用快照，请点击刷新"}
            busy=false
        }
    }
    func refresh() {
        guard !busy,!settings.executable.isEmpty,!settings.configuration.isEmpty else {return}
        busy=true;failure=nil;localFailedSource=nil;lastRefresh=Date();let current=settings;let token=generation;let expected=snapshot?.configuration_fingerprint
        Task {
            do {
                let result=try await Task.detached(priority:.userInitiated) {try LocalCollector.refreshResult(current,expectedLocalFingerprint:expected)}.value
                if token==generation {apply(result,restored:false)}
            } catch UsageError.configurationChanged {snapshot=nil;fleet=nil;stale=false;failure="配置已变更或不可读取，请刷新或检查配置"}
            catch UsageError.sourceFailure(let source) {localFailedSource=source;failure="采集失败，来源："+source;stale=hasResult}
            catch {failure="采集失败，保留上次成功结果";stale=hasResult}
            busy=false
        }
    }
}
