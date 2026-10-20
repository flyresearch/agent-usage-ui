import AppKit
import SwiftUI
import TokenBarCore

/// Product identity is independent of the selected data source. Switching to
/// native Syrtis features must never enable the upstream updater or migration.
enum AgentUsageProduct {
    static let identifier="org.flyresearch.agentusage"
    static var enabled:Bool {
        Bundle.main.bundleIdentifier==identifier ||
        Bundle.main.object(forInfoDictionaryKey:"AgentUsageOffline") as? Bool == true ||
        CommandLine.arguments.contains("--fleet-offline") || CommandLine.arguments.contains("--agent-usage-native")
    }
    static func prepareNativeStorage() throws {
        guard enabled,!FleetMode.enabled,!DemoData.ignoresLocalVisibility else {return}
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // Preserve the engine's native configuration/import roots and custom
        // pricing. Its source config is not an application-owned cache path.
        // Only app-owned identity/history storage changes namespace, before FFI.
        guard setenv("AGENT_USAGE_NATIVE_RUNTIME","1",1)==0 else {throw CocoaError(.fileWriteUnknown)}
    }
}
enum AgentUsageMode:String,CaseIterable {
    case native,fleet
    static let key="agentusage.dataMode"
    static func resolve(arguments:[String],stored:String?,hasFleetConfiguration:Bool) -> Self {
        if arguments.contains("--fleet-offline") {return .fleet}
        if arguments.contains("--agent-usage-native") {return .native}
        if let stored,let mode=Self(rawValue:stored) {return mode}
        // Existing fleet installations keep their chosen setup. New installs
        // start with the original local experience, without fabricating a fleet.
        return hasFleetConfiguration ? .fleet:.native
    }
    static var current:Self {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        return resolve(arguments:CommandLine.arguments,stored:UserDefaults.standard.string(forKey:key),
                       hasFleetConfiguration:FileManager.default.fileExists(atPath:root.appendingPathComponent("AgentUsageOffline/connection.json").path))
    }
    var title:String {self == .native ? "本机 · Syrtis 完整功能".localized:"多机 · Agent Usage 汇总".localized}
}

struct AgentUsageModeSettings:View {
    @AppStorage(AgentUsageMode.key) private var stored=""
    @SyrtisState private var restart=false
    @SyrtisState private var pendingMode:AgentUsageMode?
    @SyrtisState private var historyBusy=false
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("数据范围".localized).font(.caption.bold())
            Picker("启动后使用".localized,selection:Binding(get:{AgentUsageMode(rawValue:stored) ?? AgentUsageMode.current},set:{mode in
                pendingMode=mode;restart=true
            })) {
                ForEach(AgentUsageMode.allCases,id:\.self) {Text($0.title).tag($0)}
            }.disabled(historyBusy)
            Text("本机保留 Syrtis 原版来源、账号、额度、归属与会话功能，并按原生账号配置查询额度。多机使用独立 collector 汇总已配置机器；两种范围不相加。切换后重启生效。".localized)
                .font(.caption2).foregroundStyle(.secondary)
            Text("查看范围不影响已启用的多机后台采集。".localized).font(.caption2).foregroundStyle(.secondary)
            Text("当前：".localized+(FleetMode.enabled ? AgentUsageMode.fleet.title:AgentUsageMode.native.title)).font(.caption2)
            AgentUsagePreferencesMigrationView()
            AgentUsageHistoryMigrationView(busy:$historyBusy)
            if !FleetMode.enabled {DisclosureGroup("多机连接配置".localized) {FleetConnectionSettings()}}
        }.padding(10).glassCard(cornerRadius:8)
        .disabled(DemoData.ignoresLocalVisibility)
        .alert("切换数据范围".localized,isPresented:$restart) {
            Button("重启并切换".localized) {if let pendingMode {stored=pendingMode.rawValue;AppRelauncher.relaunch(arguments:[pendingMode == .native ? "--agent-usage-native":"--fleet-offline"])}}
            Button("Cancel".localized,role:.cancel) {pendingMode=nil}
        } message: {Text("本机模式会启用原版账号与额度服务；应用快照、偏好和更新渠道保持 Agent Usage 独立身份。已有多机配置会保留。".localized)
            if pendingMode == .native {Text("如需旧额度历史，请先取消切换并在下方完成迁移。".localized)}
        }
    }
}


struct AgentUsageScopeHeader:View {
    var body:some View {
        HStack {
            Label(FleetMode.enabled ? "多机汇总 · 已知用量".localized:"本机 · Syrtis 原版口径".localized,systemImage:FleetMode.enabled ? "network":"desktopcomputer")
            Spacer()
            Button("切换范围".localized) {SettingsWindowController.shared.showFromPopover(scrollingTo:.dataScope)}
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }.font(.caption).padding(.horizontal,16).padding(.bottom,8)
    }
}
