import Foundation
import SwiftUI
import TokenBarCore

/// Display preferences only. Account bindings, credentials, provider paths,
/// update settings and source configuration are deliberately outside this plan.
@MainActor enum AgentUsagePreferencesMigration {
    static let backupKey="agentusage.preferenceImport"
    static let allowed:Set<String>=[
        TrayMode.storageKey,TrayAnimator.styleKey,TrayAnimator.animateKey,
        AnimationPace.storageKey,PopoverChrome.heightKey,
        MenuBarTextColor.storageKey,MenuBarTextColor.customColorKey,
        ClientRegistry.tabOrderKey,ClientRegistry.tabHiddenKey,ClientRegistry.limitsHiddenKey,
        OverviewCard.hiddenKey,"tokenbar.limits.enabled","tokenbar.limits.asUsed",
        "tokenbar.limits.layout"
    ]
    static func plan(source:[String:Any],existing:[String:Any]) -> [String:Any] {
        source.filter { key,value in
            guard allowed.contains(key),existing[key]==nil else {return false}
            if let string=value as? String {return string.utf8.count<=65536}
            return value is NSNumber
        }
    }
    @discardableResult static func apply(_ plan:[String:Any],defaults:UserDefaults,domain:String) -> Int {
        let existing=defaults.persistentDomain(forName:domain) ?? [:]
        let accepted=Self.plan(source:plan,existing:existing)
        guard !accepted.isEmpty else {return 0}
        var backup=defaults.dictionary(forKey:backupKey) ?? [:]
        for (key,value) in accepted {defaults.set(value,forKey:key);backup[key]=value}
        defaults.set(backup,forKey:backupKey)
        return accepted.count
    }
    @discardableResult static func undo(defaults:UserDefaults,domain:String) -> Int {
        let existing=defaults.persistentDomain(forName:domain) ?? [:]
        let backup=defaults.dictionary(forKey:backupKey) ?? [:]
        var removed=0
        for (key,value) in backup where allowed.contains(key) {
            // Keep any setting the user edited after import.
            if let current=existing[key] as? NSObject,current.isEqual(value) {
                defaults.removeObject(forKey:key);removed+=1
            }
        }
        defaults.removeObject(forKey:backupKey)
        return removed
    }
}

struct AgentUsagePreferencesMigrationView:View {
    @SyrtisState private var preview=[String:Any]()
    @SyrtisState private var notice=""
    @SyrtisState private var canUndo=false
    private var domain:String {Bundle.main.bundleIdentifier ?? AgentUsageProduct.identifier}
    private func reload() {
        guard !DemoData.ignoresLocalVisibility else {return}
        let source=UserDefaults.standard.persistentDomain(forName:"com.nyanako.tokenbar") ?? [:]
        preview=AgentUsagePreferencesMigration.plan(source:source,existing:UserDefaults.standard.persistentDomain(forName:domain) ?? [:])
        canUndo=UserDefaults.standard.dictionary(forKey:AgentUsagePreferencesMigration.backupKey)?.isEmpty == false
    }
    var body:some View {
        DisclosureGroup("导入 Syrtis 显示偏好".localized) {
            VStack(alignment:.leading,spacing:8) {
                Text("可导入 %lld 项显示偏好。只补充当前未设置的值，不覆盖现有偏好；不导入账号、票据、路径、额度历史或更新设置。原 Syrtis 保持不变。".localized(preview.count))
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("导入预览中的偏好".localized) {
                        let n=AgentUsagePreferencesMigration.apply(preview,defaults:.standard,domain:domain)
                        notice="已导入 %lld 项".localized(n);reload()
                    }.disabled(preview.isEmpty)
                    Button("撤销上次导入".localized) {
                        let n=AgentUsagePreferencesMigration.undo(defaults:.standard,domain:domain)
                        notice="已撤销 %lld 项；与导入值不同的设置已保留".localized(n);reload()
                    }.disabled(!canUndo)
                }
                if !notice.isEmpty {Text(notice).font(.caption2)}
            }.padding(.top,8)
        }.font(.caption).onAppear {reload()}.disabled(DemoData.ignoresLocalVisibility)
    }
}

struct AgentUsageHistoryMigrationView:View {
    @SyrtisState private var preview:TBCore.NativeHistoryImport?
    @Binding var busy:Bool
    @SyrtisState private var notice=""
    @MainActor private func run(commit:Bool) async {
        guard !DemoData.ignoresLocalVisibility else {return}
        busy=true
        defer {busy=false}
        do {
            let value=try await Task.detached(priority:.utility) {try TBCore.nativeHistoryImport(commit:commit)}.value
            guard !Task.isCancelled else {return}
            preview=commit ? nil:value
            notice=commit ? "历史已导入，原 Syrtis 文件未修改。切换本机范围后可使用。".localized:"可导入 %lld 条额度历史曲线。".localized(value.seriesCount)
        } catch {
            preview=nil
            let code:String
            if case TBCoreError.bridge(let value)=error {code=value} else {code=""}
            switch code {
            case "history_import_destination_exists":notice="Agent Usage 已有本机历史存储，不能覆盖或直接合并。".localized
            case "history_import_missing":notice="没有找到可完整迁移的 Syrtis 历史及账号标识文件。".localized
            case "history_import_busy":notice="Syrtis 正在更新历史，请稍后重新检查。".localized
            default:notice="无法安全导入历史；原文件保持不变。请检查文件完整性和访问权限。".localized
            }
        }
    }
    var body:some View {
        DisclosureGroup("迁移旧额度历史".localized) {
            VStack(alignment:.leading,spacing:8) {
                Text("首次使用本机范围前，可把 Syrtis 的额度历史及配套历史标识一起复制到独立存储。仅支持空目标，不合并不同历史，不复制登录票据。原文件保留供回退。".localized)
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("检查可迁移历史".localized) {Task {await run(commit:false)}}.disabled(busy)
                    Button("导入历史".localized) {Task {await run(commit:true)}}.disabled(busy || preview==nil)
                    if busy {ProgressView().controlSize(.small)}
                }
                if !notice.isEmpty {Text(notice).font(.caption2).foregroundStyle(.secondary)}
            }.padding(.top,8)
        }.font(.caption).disabled(DemoData.ignoresLocalVisibility)
    }
}
