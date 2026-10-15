import AppKit
import SwiftUI
import Charts
import UsageCore

/// Offline counterpart of Syrtis's header / client tabs / lenses / cards / footer.
struct UsageMenu:View {
    @ObservedObject var store:DashboardStore
    @Environment(\.openWindow) private var openWindow
    private var summary:MenuSummary? {try? MenuSummary(fleet:store.fleet,snapshot:store.snapshot,host:store.menuHost == "all" ? nil : store.menuHost,agent:store.menuAgent == "all" ? nil : store.menuAgent,period:store.menuPeriod)}
    private func open(_ settings:Bool=false) {openWindow(id:"dashboard");NSApp.activate(ignoringOtherApps:true);if settings {store.beginSettings()}}
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label("Agent Usage",systemImage:"chart.bar.xaxis").font(.headline).foregroundStyle(.indigo)
                Spacer()
                if store.busy {ProgressView().controlSize(.small).accessibilityLabel("正在刷新")}
                Button(action:store.refresh) {Image(systemName:"arrow.clockwise")}.disabled(store.busy || store.settings.configuration.isEmpty).help("刷新用量").accessibilityLabel("刷新用量")
            }.padding(16)
            HStack {
                Picker("时间范围",selection:$store.menuPeriod) {ForEach(MenuPeriod.allCases,id:\.self) {Text($0.title).tag($0)}}.labelsHidden()
                Picker("机器",selection:$store.menuHost) {
                    Text("全部机器").tag("all")
                    if let fleet=store.fleet {ForEach(fleet.hosts) {Text($0.host_id).tag($0.host_id)}}
                }.labelsHidden()
            }.padding(.horizontal,16)
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:6) {
                    agentButton("all","全部")
                    ForEach(["codex","claude","agy","hermes","openclaw"],id:\.self) {agentButton($0,$0 == "agy" ? "agy" : $0.capitalized)}
                }.padding(.horizontal,16).padding(.vertical,10)
            }
            Picker("视图",selection:$store.menuPage) {ForEach(["概览","模型","机器"],id:\.self) {Text($0).tag($0)}}.pickerStyle(.segmented).padding(.horizontal,16).padding(.bottom,12)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    status
                    if store.menuPage == "机器" {hosts}
                    else if let summary,let tokens=summary.tokens {
                        VStack(alignment:.leading,spacing:6) {
                            Text("\(store.menuPeriod.title)已知用量").font(.caption).foregroundStyle(.secondary)
                            Text((try? tokens.total.formatted()) ?? "—").font(.system(size:30,weight:.semibold,design:.rounded)).monospacedDigit()
                            Text("Token · Asia/Singapore").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(14).background(.indigo.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
                        if store.menuPage == "模型" {buckets(summary.models,title:"模型分布")}
                        else {
                            VStack(spacing:7) {
                                metric("输入",tokens.input);metric("缓存读取",tokens.cache_read);metric("缓存写入",tokens.cache_write);metric("输出",tokens.output);metric("推理",tokens.reasoning)
                            }
                            if !summary.days.isEmpty {
                                Text("每日用量").font(.subheadline.weight(.semibold))
                                Chart(summary.days) {day in BarMark(x:.value("日期",day.id),y:.value("Token",day.value)).foregroundStyle(.indigo)}.frame(height:100).chartXAxis(.hidden)
                                HStack {Text(summary.days.first?.id ?? "");Spacer();Text(summary.days.last?.id ?? "")}.font(.caption2).foregroundStyle(.secondary)
                            }
                            buckets(summary.agents,title:"Agent 分布")
                        }
                        if summary.unallocated>0 {Text("未分摊日期：\(summary.unallocated.formatted()) Token；\(store.menuPeriod == .all ? "已包含在全部用量中" : "未计入当前日期范围")。").font(.caption).foregroundStyle(.secondary)}
                    } else {
                        ContentUnavailableView("尚无可用用量",systemImage:"chart.bar",description:Text(store.settings.configuration.isEmpty ? "请先在连接设置中配置采集器" : "请刷新；未采集或配置已变更的机器不显示为零"))
                    }
                    Text("已知用量，不等同于完整账单。\(store.coverageComplete ? "" : "历史覆盖存在缺口。")").font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
            }.frame(height:410)
            Divider()
            HStack {
                Button("打开面板") {open()}
                Spacer()
                Button {open(true)} label:{Image(systemName:"gearshape")}.help("连接设置").accessibilityLabel("连接设置")
                Button("退出") {NSApp.terminate(nil)}
            }.controlSize(.small).padding(12)
        }.frame(width:420).background(.regularMaterial)
    }
    private func agentButton(_ id:String,_ title:String)->some View {
        Button {store.menuAgent=id} label:{Text(title).font(.caption.weight(.medium)).padding(.horizontal,9).padding(.vertical,6).background(store.menuAgent==id ? Color.indigo.opacity(0.18) : Color.secondary.opacity(0.07),in:Capsule())}.buttonStyle(.plain).accessibilityAddTraits(store.menuAgent==id ? .isSelected : [])
    }
    @ViewBuilder private var status:some View {
        Label(store.busy ? "正在刷新，显示上次结果" : store.stale ? "含上次成功快照" : store.hasResult ? "已同步" : "尚未采集",systemImage:store.stale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").font(.caption).foregroundStyle(store.stale ? .orange : .secondary)
        if let failure=store.failure {Text(failure).font(.caption).foregroundStyle(.orange)}
        if let fleet=store.fleet {
            Text("\(fleet.hosts.filter{$0.state=="fresh"}.count)/\(fleet.hosts.count) 台机器已同步").font(.caption).foregroundStyle(.secondary)
            ForEach(fleet.hosts.filter{$0.state != "fresh"}) {h in
                Text("\(h.host_id)：\(h.stateLabel)\(h.error.map{" · "+$0} ?? "")\(h.failed_source_id.map{" · 来源 "+$0} ?? "")").font(.caption).foregroundStyle(.orange)
            }
        }
    }
    private func metric(_ title:String,_ value:UInt64)->some View {HStack {Text(title).foregroundStyle(.secondary);Spacer();Text(value.formatted()).monospacedDigit()}.font(.caption)}
    private func buckets(_ values:[MenuBucket],title:String)->some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.subheadline.weight(.semibold))
            if values.isEmpty {Text("当前范围无已知记录").font(.caption).foregroundStyle(.secondary)}
            ForEach(values) {b in
                VStack(spacing:4) {HStack {Text(b.id).lineLimit(2);Spacer();Text(MenuSummary.compact(b.value)).monospacedDigit()}.font(.caption);ProgressView(value:Double(b.value),total:max(1,Double(values.first?.value ?? 0))).tint(.indigo)}
            }
        }
    }
    @ViewBuilder private var hosts:some View {
        if let fleet=store.fleet {
            Text("机器状态 · 用量遵循当前时间与 Agent 筛选").font(.caption).foregroundStyle(.secondary)
            ForEach(fleet.hosts.filter{store.menuHost=="all" || $0.host_id==store.menuHost}) {h in
                VStack(alignment:.leading,spacing:6) {
                    HStack {Text(h.host_id).font(.subheadline.weight(.semibold));Spacer();Text(h.stateLabel).font(.caption).foregroundStyle(h.state=="fresh" ? .green : .orange)}
                    let value=try? MenuSummary(fleet:fleet,snapshot:nil,host:h.host_id,agent:store.menuAgent=="all" ? nil : store.menuAgent,period:store.menuPeriod)
                    Text(value?.tokens.flatMap{try? $0.total.formatted()} ?? "尚无当前配置用量").monospacedDigit()
                    if let time=h.last_success_at {Text("上次成功："+time).font(.caption2).foregroundStyle(.secondary)}
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
            }
        } else {Text(store.snapshot?.host_id ?? "尚未配置机器").font(.subheadline)}
    }
}
