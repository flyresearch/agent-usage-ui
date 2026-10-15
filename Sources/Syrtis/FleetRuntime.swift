import AppKit
import SwiftUI
import Observation
import UsageCore

@MainActor @Observable final class FleetUIState {
    static let shared=FleetUIState()
    var fleet:FleetSnapshot?
    var local:UsageSnapshot?
    var error:String?
    var noCurrentData:Bool {
        if let fleet {let host=UserDefaults.standard.string(forKey:"agentusage.selectedHost").flatMap{$0.isEmpty ? nil:$0};return !fleet.hasData(host:host)}
        return local==nil
    }
    func accept(_ result:CollectionResult) {
        switch result {case .fleet(let f):fleet=f;local=nil;case .local(let s):local=s;fleet=nil}
        error=nil
    }
}

@MainActor final class FleetRuntime {
    static let shared=FleetRuntime()
    private var controller:StatusItemController?
    private var animator:TrayAnimator?
    private var task:Task<Void,Never>?
    func start() {
        UserDefaults.standard.register(defaults:[TrayAnimator.styleKey:"agent-usage"])
        let controller=StatusItemController();self.controller=controller
        if let icon=NSImage(systemSymbolName:"chart.bar.fill",accessibilityDescription:"Agent Usage") {controller.setStaticIcon(icon,isTemplate:true)}
        controller.updateTitle("今日 —")
        let animator=TrayAnimator(controller:controller,source:FleetUsageDataSource.shared);self.animator=animator;animator.start()
        task=Task {
            while !Task.isCancelled {
                do {
                    let result=try await FleetUsageDataSource.shared.result()
                    let summary:MenuSummary
                    let stale:Bool
                    switch result {
                    case .fleet(let f):summary=try MenuSummary(fleet:f,snapshot:nil,period:.today);stale = !f.complete
                    case .local(let s):summary=try MenuSummary(fleet:nil,snapshot:s,period:.today);stale=false
                    }
                    let value=try summary.tokens?.total
                    let mode=TrayMode(rawValue:UserDefaults.standard.string(forKey:TrayMode.storageKey) ?? "") ?? .todayTokens
                    let title:String
                    switch mode {
                    case .hidden:title=""
                    case .todayCost,.totalCost:
                        let rows:[UsageRow]
                        switch result {case .fleet(let f):rows=f.selected();case .local(let s):rows=s.rows}
                        let scoped=mode == .todayCost ? rows.filter{$0.day==MenuPeriod.day(Date())}:rows
                        let estimate=try FleetMetrics.catalog?.summary(scoped)
                        title=estimate?.doubleValue.map{String(format:"≈$%.2f",$0)+(estimate?.complete == true ? "":"*")} ?? "金额 —"
                    case .totalTokens:
                        let total:UInt64?
                        switch result {case .fleet(let f):total=try f.totals?.total;case .local(let s):total=try s.totals.total}
                        title=total.map(MenuSummary.compact) ?? "—"
                    default:title=value.map(MenuSummary.compact) ?? "—"
                    }
                    controller.updateTitle(title,stale:stale)
                } catch {
                    FleetUIState.shared.error="采集失败，保留上次成功结果"
                    controller.updateTitle("用量待刷新",stale:true)
                }
                do {try await Task.sleep(for:.seconds(60))} catch {return}
            }
        }
        if CommandLine.arguments.contains("--open-popover") {controller.showPopover()}
    }
}

struct FleetStatusHeader:View {
    var clients:[String]=[]
    var year:String?=nil
    @AppStorage("agentusage.selectedHost") private var selectedHost=""
    var changed:() -> Void
    var body:some View {
        let state=FleetUIState.shared
        VStack(alignment:.leading,spacing:6) {
            if let fleet=state.fleet {
                Picker("机器",selection:$selectedHost) {
                    Text("全部机器").tag("")
                    ForEach(fleet.hosts) {Text($0.host_id).tag($0.host_id)}
                }.onChange(of:selectedHost) {_,_ in changed()}
                Text("\(fleet.hosts.filter{$0.state=="fresh"}.count)/\(fleet.hosts.count) 台已同步 · Asia/Singapore").font(.caption).foregroundStyle(.secondary)
                ForEach(fleet.hosts.filter{$0.state != "fresh"}) {h in Text("\(h.host_id)：\(h.stateLabel)\(h.error.map{" · "+$0} ?? "")").font(.caption).foregroundStyle(.orange)}
            }
            if let error=state.error {Text(error).font(.caption).foregroundStyle(.orange)}
            let host=selectedHost.isEmpty ? nil:selectedHost
            if let summary=try? MenuSummary(fleet:state.fleet,snapshot:state.local,host:host,period:.all),summary.unallocated>0 {Text("未分摊日期：\(summary.unallocated.formatted()) Token").font(.caption).foregroundStyle(.secondary)}
            Text(FleetMetrics.note(clients:clients,year:year)).font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal,16).padding(.bottom,10)
    }
}

struct FleetConnectionSettings:View {
    @SyrtisState private var executable=""
    @SyrtisState private var configuration=""
    @SyrtisState private var fleet=true
    @SyrtisState private var auto=true
    @SyrtisState private var message=""
    private var root:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AgentUsageOffline")}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("采集连接").font(.headline)
            TextField("采集器绝对路径",text:$executable)
            TextField("配置绝对路径",text:$configuration)
            Toggle("多机汇总",isOn:$fleet)
            Toggle("每五分钟自动采集",isOn:$auto)
            Button("保存并刷新") {
                guard executable.hasPrefix("/"),configuration.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:executable) else {message="请选择有效的采集器和配置路径";return}
                do {
                    let old=try JSONDecoder().decode(CollectorSettings.self,from:Data(contentsOf:root.appendingPathComponent("connection.json")))
                    var value=old;value.executable=executable;value.configuration=configuration;value.fleetMode=fleet;value.autoRefresh=auto
                    try JSONEncoder().encode(value).write(to:root.appendingPathComponent("connection.json"),options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("connection.json").path)
                    DashboardModel.invalidateScanDerivedCaches()
                    FleetUIState.shared.fleet=nil;FleetUIState.shared.local=nil
                    message="已保存；重新打开浮层后刷新"
                } catch {message="保存失败，请检查本地配置"}
            }
            Text(message).font(.caption)
            Text("仅调用已配置采集器，不读取模型服务凭据。金额为目录价估算；在线额度和实时速率不可用。").font(.caption).foregroundStyle(.secondary)
        }.task {
            if let value=try? JSONDecoder().decode(CollectorSettings.self,from:Data(contentsOf:root.appendingPathComponent("connection.json"))) {executable=value.executable;configuration=value.configuration;fleet=value.fleetMode == true;auto=value.autoRefresh != false}
        }
    }
}

@MainActor enum FleetMetrics {
    static let catalog=try? PriceCatalog.bundled()
    static func rows(clients:[String],year:String?) -> [UsageRow] {
        let state=FleetUIState.shared
        let host=UserDefaults.standard.string(forKey:"agentusage.selectedHost").flatMap{$0.isEmpty ? nil:$0}
        let rows=state.fleet?.selected(host:host) ?? state.local?.rows ?? []
        return rows.filter {r in (clients.isEmpty || clients.contains(r.agent)) && (year==nil || r.day?.hasPrefix(year!+"-")==true)}
    }
    static func note(clients:[String],year:String?) -> String {
        guard !FleetUIState.shared.noCurrentData else {return "尚无当前配置的可用用量"}
        let rows=rows(clients:clients,year:year)
        let count=try? MessageCount.total(rows)
        let cost=try? catalog?.summary(rows)
        let countText=count.map {if $0.known==0 && !$0.complete {return "已计量响应/API 调用：—（计数未覆盖）"};return "已计量响应/API 调用：\($0.known.formatted())\($0.complete ? "" : "（部分来源未覆盖）")"} ?? "响应计数不可用"
        guard let cost else {return countText+" · 价格目录不可用"}
        let ratio=cost.totalTokens>0 ? Double(cost.pricedTokens)/Double(cost.totalTokens)*100:100
        return countText+"\n目录价估算："+(cost.doubleValue.map{String(format:"≈$%.2f",$0)} ?? "—")+String(format:" · 已定价 Token %.1f%%",ratio)+"\n价格版本 "+cost.version+" · 标准短上下文/5m 缓存/峰值；不等于账单或完整对话数。"
    }
}
