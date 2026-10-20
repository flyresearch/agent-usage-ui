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
    var revision=UUID()
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
        revision=UUID()
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
    private var clientIDs:[String]=[]

    private func reconcileClientItems() {
        controller?.reconcileClientItems(ClientTray.runtimePresentations(
            clients:clientIDs,payload:animator?.quota,
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
                    clientIDs=await FleetPresentation.shared.clients(result)
                } catch UsageError.configurationChanged {clientIDs=[]}
                catch {if FleetUIState.shared.noCurrentData {clientIDs=[]}}
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
                    let mode=TrayMode.current
                    var display=try await FleetPresentation.shared.menu(result,mode:mode)
                    if mode == .tokensPerMin {
                        if let rate=try? await LiveRate.current(source:FleetUsageDataSource.shared),rate.isFinite,rate>=0,rate<Double(UInt64.max) {
                            display.title=(rate<10 ? String(format:"%.1f/m",rate):MenuSummary.compact(UInt64(rate))+"/m")+(FleetUIState.shared.activity?.complete == true ? "":"*")
                        } else {display.title="速率 —"}
                    }
                    guard TrayMode.current==mode else {continue}
                    controller.updateTitle(display.title,stale:display.stale)
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
    @SyrtisState private var report:FleetHeaderReport?
    @SyrtisState private var reportKey:FleetHeaderKey?
    var body:some View {
        let state=FleetUIState.shared
        let configuration=state.fleet?.configuration_fingerprint ?? state.local.map{$0.host_id+"|"+$0.configuration_fingerprint}
        let available=state.fleet?.hasData(host:selectedHost.isEmpty ? nil:selectedHost) ?? (state.local != nil)
        let key=FleetHeaderKey(revision:state.revision,host:selectedHost,clients:clients.sorted(),year:year,configuration:configuration,available:available)
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
            if (reportKey==key || key.canRetain(reportKey)),let report {
                if report.unallocated>0 {Text("未分摊日期：\(report.unallocated.formatted()) Token").font(.caption).foregroundStyle(.secondary)}
                Text(report.note).font(.caption2).foregroundStyle(.secondary)
            } else {Text("正在更新统计说明…").font(.caption2).foregroundStyle(.secondary)}
            FleetCoverageView(report: CoverageReport(fleet:state.fleet,snapshot:state.local,host:host,refreshFailed:state.error != nil))
        }.padding(.horizontal,16).padding(.bottom,10)
        .task(id:key) {
            let fleet=state.fleet,local=state.local
            let value=await FleetPresentation.shared.header(fleet:fleet,local:local,host:key.host,clients:key.clients,year:key.year)
            guard !Task.isCancelled,state.revision==key.revision else {return}
            report=value;reportKey=key
        }
    }
}
