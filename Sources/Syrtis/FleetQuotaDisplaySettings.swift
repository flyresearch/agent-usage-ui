import SwiftUI
import TokenBarCore

/// Presentation controls never write collector or provider configuration.
struct FleetQuotaDisplaySettings: View {
    @AppStorage("tokenbar.limits.enabled") private var enabled = true
    @AppStorage("tokenbar.limits.asUsed") private var asUsed = false
    @AppStorage(FleetQuotaPolicy.historyVisibleKey) private var historyVisible = true
    @AppStorage(ClientRegistry.limitsHiddenKey) private var hiddenRaw = ""
    @AppStorage(ClientRegistry.tabHiddenKey) private var tabsHiddenRaw = ""
    @AppStorage(ClientRegistry.tabOrderKey) private var orderRaw = ""

    var body: some View { controls.glassCard(cornerRadius:8) }

    // Shared content also supports offscreen layout checks without compositor glass.
    var controls: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("在线额度显示").font(.caption.bold())
            toggle("显示在线额度卡片",isOn:$enabled)
            Text("同时控制概览和额度页。隐藏不停止查询，也不删除历史。").font(.caption2).foregroundStyle(.secondary)
            if enabled {
                toggle("进度条显示已用额度",isOn:$asUsed)
                Text("关闭时显示剩余额度；数字始终同时列出已用和剩余。").font(.caption2).foregroundStyle(.secondary)
                toggle("显示额度历史与趋势",isOn:$historyVisible)
                Text("关闭后继续记录历史，需要时可重新展开。").font(.caption2).foregroundStyle(.secondary)
                Divider()
                let hidden = ClientRegistry.parseIdSet(hiddenRaw)
                let tabsHidden = ClientRegistry.hiddenTabClients(ClientRegistry.parseIdSet(tabsHiddenRaw))
                ForEach(ClientRegistry.orderedClients(FleetQuotaPolicy.clients,orderRaw:orderRaw),id: \.self) { id in
                    toggle(ClientRegistry.shortName(id),isOn:Binding(
                        get:{!tabsHidden.contains(id) && !hidden.contains(id)},
                        set:{show in
                            var next=ClientRegistry.parseIdSet(hiddenRaw)
                            if show {next.remove(id)} else {next.insert(id)}
                            hiddenRaw=next.sorted().joined(separator:",")
                        }))
                        .disabled(tabsHidden.contains(id))
                }
                Text("隐藏卡片保留 Agent 标签；标签隐藏时，对应卡片也隐藏。卡片顺序跟随 Agent 标签顺序。菜单栏自动选择也会跳过隐藏的额度来源，明确指定的窗口不受影响。").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(10)
    }

    private func toggle(_ title:String,isOn:Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("",isOn:isOn).labelsHidden().accessibilityLabel(title)
        }
    }

}
