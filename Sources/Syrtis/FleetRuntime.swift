import AppKit
import SwiftUI
import Observation
import UsageCore
import TokenBarCore

@MainActor @Observable final class NativeQuotaPresentation {
    var quotaEnabled=false
    var quotaLoading=false
    var quotaGeneration:UInt64=0
    var quota:NativeQuotaSnapshot?
    var quotaMessage:String?
    var history:[QuotaObservation]=[]
    var historyMessage:String?
}

@MainActor @Observable final class FleetUIState {
    static let shared=FleetUIState()
    var fleet:FleetSnapshot?
    var local:UsageSnapshot?
    var error:String?
    var liveEnabled=false
    var activity:LiveActivityReport?
    let codexQuota=NativeQuotaPresentation()
    let agyQuota=NativeQuotaPresentation()
    let claudeQuota=NativeQuotaPresentation()
    func quotaState(_ provider:NativeQuotaProvider) -> NativeQuotaPresentation {provider == .codex ? codexQuota:provider == .agy ? agyQuota:claudeQuota}
    var allClients:[String] {
        Array(Set((fleet?.selected() ?? local?.rows ?? []).map(\.agent))).sorted()
    }
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
    private var quotaTask:Task<Void,Never>?
    private var clientTask:Task<Void,Never>?
    private var preferencesObserver:NSObjectProtocol?
    private var clientPreferenceSignature=""
    private var clientGraph:UsagePayload?
    private let clientProjection=FleetUsageDataSource(selectedHost:{nil})

    private func reconcileClientItems() {
        controller?.reconcileClientItems(ClientTray.runtimePresentations(
            graph:clientGraph,payload:animator?.quota,
            enabled:ClientTray.enabled(),selections:ClientTray.selections(),
            hidden:ClientRegistry.hiddenTabClients(),
            officialClients:AgentIconView.availableOfficialClientIDs(),missingSnapshotIsTransient:true))
    }
    private func reconcileClientPreferences() {
        let keys=[ClientTray.enabledKey,ClientTray.selectionsKey,ClientRegistry.tabHiddenKey,
                  MenuBarTextColor.storageKey,MenuBarTextColor.customColorKey,
                  MenuBarTextColor.warningColorKey,MenuBarTextColor.criticalColorKey]
        let signature=keys.map{UserDefaults.standard.string(forKey:$0) ?? ""}.joined(separator:"|")
        guard signature != clientPreferenceSignature else {return}
        clientPreferenceSignature=signature;reconcileClientItems()
    }
    func start() {
        UserDefaults.standard.register(defaults:[TrayAnimator.styleKey:"agent-usage"])
        let controller=StatusItemController();self.controller=controller
        if let icon=NSImage(systemSymbolName:"chart.bar.fill",accessibilityDescription:"Agent Usage") {controller.setStaticIcon(icon,isTemplate:true)}
        controller.updateTitle("今日 —")
        let animator=TrayAnimator(controller:controller,source:FleetUsageDataSource.shared);self.animator=animator;controller.quotaPayloadProvider = { [weak animator] in animator?.quota };animator.start()
        animator.onQuotaUpdated={ [weak self] in self?.reconcileClientItems() }
        preferencesObserver=NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileClientPreferences() }
        }
        clientTask=Task {
            while !Task.isCancelled {
                do {
                    let result=try await FleetUsageDataSource.shared.result()
                    clientGraph=try await clientProjection.projectGraph(result,year:nil)
                } catch UsageError.configurationChanged {clientGraph=nil}
                catch {if FleetUIState.shared.noCurrentData {clientGraph=nil}}
                reconcileClientItems()
                do {try await Task.sleep(for:.seconds(10))} catch {return}
            }
        }
        quotaTask=Task {
            while !Task.isCancelled {
                await FleetUsageDataSource.shared.refreshAllQuotas()
                do {try await Task.sleep(for:.seconds(10))} catch {return}
            }
        }
        task=Task {
            while !Task.isCancelled {
                if TrayMode.current == .quotaLeft {
                    let remaining=animator.quotaRemaining
                    controller.updateTitle(remaining.map{String(format:"%.0f%%",$0)} ?? "额度 —",stale:remaining == nil)
                    do {try await Task.sleep(for:.seconds(10))} catch {return}
                    continue
                }
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
                    case .tokensPerMin:
                        if let rate=try? await LiveRate.current(source:FleetUsageDataSource.shared),rate.isFinite,rate>=0,rate<Double(UInt64.max) {
                            title=(rate<10 ? String(format:"%.1f/m",rate):MenuSummary.compact(UInt64(rate))+"/m")+(FleetUIState.shared.activity?.complete == true ? "":"*")
                        } else {title="速率 —"}
                    case .quotaLeft:title="额度 —"
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
                do {try await Task.sleep(for:.seconds(10))} catch {return}
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
            FleetCoverageView(report: CoverageReport(fleet:state.fleet,snapshot:state.local,host:host,refreshFailed:state.error != nil))
            Text(FleetMetrics.note(clients:clients,year:year)).font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal,16).padding(.bottom,10)
    }
}

@MainActor enum FleetMetrics {
    static let catalog=try? PriceCatalog.bundled()
    static func rows(clients:[String],year:String?) -> [UsageRow] {
        let state=FleetUIState.shared
        let host=UserDefaults.standard.string(forKey:"agentusage.selectedHost").flatMap{$0.isEmpty ? nil:$0}
        let rows=state.fleet?.selected(host:host) ?? state.local?.rows ?? []
        return rows.filter {r in clients.contains(r.agent) && (year==nil || r.day?.hasPrefix(year!+"-")==true)}
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
