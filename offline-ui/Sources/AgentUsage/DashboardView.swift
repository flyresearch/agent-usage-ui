import AppKit
import SwiftUI
import Charts
import UsageCore

struct DashboardView: View {
    @ObservedObject var store:DashboardStore
    private let accent=Color(red:0.34,green:0.37,blue:0.93)
    private var rows:[UsageRow] {store.selectedRows}
    private var tokens:Tokens { (try? UsageSnapshot.total(rows)) ?? Tokens() }
    private var daily:[(String,UInt64)] {
        Dictionary(grouping:rows.filter{$0.day != nil},by:{$0.day!}).map {key,rows in (key,(try? UsageSnapshot.total(rows).total) ?? 0)}.sorted{$0.0 < $1.0}
    }
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:28) {
                HStack(spacing:10) {Image(systemName:"chart.bar.xaxis").font(.title2).foregroundStyle(accent);Text("Agent Usage").font(.title3.bold())}
                VStack(alignment:.leading,spacing:8) {
                    nav("Overview","square.grid.2x2")
                    nav("Daily","chart.bar")
                    nav("Models","cpu")
                    nav("Sources","externaldrive.connected.to.line.below")
                    nav("Hosts","desktopcomputer")
                }
                Spacer()
                VStack(alignment:.leading,spacing:8) {
                    Label("按需采集",systemImage:"lock.shield").font(.callout.weight(.medium))
                    Text("只读取已配置的用量数据\n不读取模型服务登录凭据").font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:12))
                Button {store.beginSettings()} label:{Label("连接设置",systemImage:"gearshape")}.buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(24).frame(width:210).background(Color(nsColor:.windowBackgroundColor))
            Divider()
            VStack(alignment:.leading,spacing:24) {
                HStack {
                    VStack(alignment:.leading,spacing:5) {Text(title).font(.system(size:28,weight:.bold));Text(store.heading).foregroundStyle(.secondary)}
                    Spacer()
                    if store.busy {ProgressView().controlSize(.small)}
                    Button(action:store.refresh) {Label("刷新",systemImage:"arrow.clockwise")}.buttonStyle(.borderedProminent).tint(accent).disabled(store.busy || store.settings.configuration.isEmpty)
                }
                if let failure=store.failure {Label(failure,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange)}
                if store.hasResult {
                    filters
                    if store.invalidDateRange && store.page != "Hosts" && store.page != "Sources" {Label("开始日期不能晚于结束日期",systemImage:"exclamationmark.triangle").foregroundStyle(.orange)}
                    ScrollView {
                        VStack(alignment:.leading,spacing:22) {
                            if store.page == "Hosts" {hostTable}
                            else if store.page == "Sources" {sourceGroups}
                            else if store.hasData && !store.invalidDateRange {
                                if store.page == "Overview" {overview}
                                if store.page == "Daily" {dailyChart;dailyTable}
                                if store.page == "Models" {modelTable}
                                if store.unallocated>0 {Text("未分摊日期的用量：\(store.unallocated.formatted()) Token。" + (store.dateRange ? "日期筛选未包含这些用量。" : "已包含在总量中，未加入每日图表。")).font(.callout).foregroundStyle(.secondary)}
                            } else if !store.hasData {
                                Label("所选机器尚无当前配置的成功快照",systemImage:"clock").font(.title3).padding(24)
                                hostTable
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,16)
                    }
                    HStack {Text("Asia/Singapore · 已知用量，不等同于完整账单");Spacer();Text(updatedAt(store.generatedAt)).lineLimit(1)}.font(.caption).foregroundStyle(.secondary)
                } else {
                    Spacer()
                    VStack(spacing:16) {
                        Image(systemName:"chart.xyaxis.line").font(.system(size:54,weight:.light)).foregroundStyle(accent)
                        Text("尚未采集").font(.title2.bold())
                        Text("选择 agent-usage 程序和你的私有配置。\n成功采集后，概览、日期和模型统计将在这里显示。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("配置连接") {store.beginSettings()}.buttonStyle(.borderedProminent).tint(accent)
                    }.frame(maxWidth:.infinity)
                    Spacer()
                }
            }.padding(30).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.controlBackgroundColor))
        }.sheet(isPresented:$store.settingsOpen) {settingsSheet}
    }
    private var filters:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                if let fleet=store.fleet {
                    Picker("机器",selection:$store.host) {Text("全部机器").tag("all");ForEach(fleet.hosts){Text($0.host_id).tag($0.host_id)}}.frame(width:210)
                }
                if store.page != "Hosts" && store.page != "Sources" {
                Picker("Agent",selection:$store.agent) {Text("全部 Agent").tag("all");ForEach(Array(Set(store.allRows.map(\.agent))).sorted(),id:\.self){Text($0).tag($0)}}.frame(width:190)
                Picker("模型",selection:$store.model) {Text("全部模型").tag("all");ForEach(Array(Set(store.allRows.filter{store.agent=="all" || $0.agent==store.agent}.map(\.model))).sorted(),id:\.self){Text($0).tag($0)}}.frame(maxWidth:260)
                }
                Spacer()
                Label(store.stale ? "含上次成功快照" : "已同步",systemImage:store.stale ? "clock" : "checkmark.circle.fill").font(.caption).foregroundStyle(store.stale ? .orange : .green)
            }
            HStack {
                if store.page != "Hosts" && store.page != "Sources" {
                Toggle("日期范围",isOn:$store.dateRange).toggleStyle(.checkbox)
                if store.dateRange {
                    DatePicker("从",selection:$store.startDate,displayedComponents:.date).frame(width:190)
                    DatePicker("至",selection:$store.endDate,displayedComponents:.date).frame(width:190)
                }
                }
                Spacer()
                if store.settings.autoRefresh != false {Text("每 5 分钟自动刷新").font(.caption).foregroundStyle(.secondary)}
            }.environment(\.timeZone,TimeZone(identifier:"Asia/Singapore")!)
        }.onChange(of:store.host){store.agent="all";store.model="all"}.onChange(of:store.agent){store.model="all"}
    }
    private var hostTable:some View {
        VStack(alignment:.leading,spacing:14) {
            if store.fleet != nil {
                ForEach(store.selectedHosts) {host in
                    VStack(alignment:.leading,spacing:10) {
                        HStack {Label(host.host_id,systemImage:"desktopcomputer").font(.headline);Spacer();Text(host.stateLabel).foregroundStyle(host.state=="fresh" ? .green : .orange)}
                        if let time=host.last_success_at {Text("上次成功 · " + updatedAt(time)).font(.caption).foregroundStyle(.secondary)}
                        if let code=host.error {Text(errorLabel(code)).foregroundStyle(.orange)}
                        if let source=host.failed_source_id {Text("失败来源：" + source).font(.caption).foregroundStyle(.orange)}
                        if !host.included {Text("尚未纳入当前总量").font(.caption).foregroundStyle(.secondary)}
                        else if let snapshot=host.snapshot {Text("整机已知用量 \((try? snapshot.totals.total.formatted()) ?? "未知") Token").monospacedDigit()}
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:14))
                }
            } else if let snapshot=store.snapshot {Text("当前为单机模式：" + snapshot.host_id).padding(20)}
        }
    }
    private var sourceGroups:some View {
        VStack(alignment:.leading,spacing:20) {
            if store.fleet != nil {
                ForEach(store.selectedHosts) {host in
                    Text(host.host_id + " · " + host.stateLabel).font(.headline)
                    if host.included,let snapshot=host.snapshot {sources(snapshot,failedSource:host.failed_source_id)}
                    else {Text("尚无当前配置的可用来源快照").foregroundStyle(.secondary)}
                }
            } else if let snapshot=store.snapshot {sources(snapshot,failedSource:store.localFailedSource)}
        }
    }
    private func errorLabel(_ code:String)->String {
        ["collection_busy":"另一项采集正在运行，将在下次刷新重试", "collection_timeout":"连接或采集超时", "collection_interrupted":"上次采集被中断", "source_missing":"配置的数据来源不存在", "source_unreadable":"无法读取配置的数据来源", "source_changed_during_scan":"来源在扫描时发生变化，将在下次刷新重试", "fleet_snapshot_identity_mismatch":"来源配置与汇总配置不一致，请更新配置", "collector_launch_failed":"无法启动采集器"][code] ?? "本次采集失败，保留上次成功结果"
    }
    private var title:String {["Overview":"用量概览","Daily":"每日用量","Models":"模型分布","Sources":"数据来源","Hosts":"机器状态"][store.page] ?? store.page}
    private func nav(_ name:String,_ icon:String)->some View {
        Button {store.page=name} label:{HStack(spacing:12){Image(systemName:icon).frame(width:20);Text(["Overview":"概览","Daily":"日期","Models":"模型","Sources":"来源","Hosts":"机器"][name] ?? name).fontWeight(.medium);Spacer()}.padding(12).background(store.page==name ? accent.opacity(0.12) : Color.clear,in:RoundedRectangle(cornerRadius:10)).foregroundStyle(store.page==name ? accent : Color.secondary)}.buttonStyle(.plain)
    }
    private func card(_ title:String,_ number:UInt64,_ note:String)->some View {
        VStack(alignment:.leading,spacing:12){Text(title).font(.callout).foregroundStyle(.secondary);Text(number.formatted(.number.notation(.compactName))).font(.system(size:30,weight:.semibold,design:.rounded));Text(note).font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading).padding(22).background(.background,in:RoundedRectangle(cornerRadius:16))
    }
    private var overview:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(spacing:16) {card("已知总用量",(try? tokens.total) ?? 0,"来自已配置的数据来源");card("输入",tokens.input,"不含读写缓存");card("缓存读取",tokens.cache_read,"独立于非缓存输入")}
            Text("本视图汇总当前日志；日志删除或移出后，成功重扫会减少历史用量。失败时保留上次成功快照。").font(.caption).foregroundStyle(.secondary)
            if !store.coverageComplete {Label("存在历史或字段覆盖缺口，请在「来源」查看详情。",systemImage:"info.circle").font(.callout).foregroundStyle(.orange).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.orange.opacity(0.07),in:RoundedRectangle(cornerRadius:12))}
            dailyChart
            HStack(spacing:16) {card("输出",tokens.output,"不含独立 reasoning");card("推理",tokens.reasoning,"来源明确提供时拆分");card("缓存写入",tokens.cache_write,"有争议分项不计入")}
        }
    }
    private var axisDates:[String] {
        let dates=Array(daily.suffix(30).map(\.0))
        let step=max(1,(dates.count+5)/6)
        return dates.enumerated().filter{$0.offset % step == 0}.map(\.element)
    }
    private func updatedAt(_ text:String)->String {
        let iso=ISO8601DateFormatter();iso.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard let date=iso.date(from:text) ?? ISO8601DateFormatter().date(from:text) else {return "更新时间未知"}
        let output=DateFormatter();output.locale=Locale(identifier:"zh_CN");output.timeZone=TimeZone(identifier:"Asia/Singapore");output.dateFormat="MM月dd日 HH:mm"
        return "更新于 " + output.string(from:date)
    }
    private var dailyChart:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text("每日已知用量").font(.headline);Spacer();Text("最近 30 个有记录日期").font(.caption).foregroundStyle(.secondary)}
            Chart(Array(daily.suffix(30)),id:\.0) {day,value in BarMark(x:.value("日期",day),y:.value("Tokens",Double(value))).foregroundStyle(accent.gradient).cornerRadius(3)}.chartXAxis {
                AxisMarks(values: axisDates) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel {if let day=value.as(String.self) {Text(String(day.suffix(5)))}}
                }
            }.chartYAxis {
                AxisMarks(position:.leading,values:.automatic(desiredCount:4)) { value in
                    AxisGridLine()
                    AxisValueLabel {if let number=value.as(Double.self) {Text(number.formatted(.number.notation(.compactName)))}}
                }
            }.frame(height:210)
        }.padding(22).background(.background,in:RoundedRectangle(cornerRadius:16))
    }
    private var dailyTable:some View {
        VStack(spacing:0) {ForEach(daily.reversed(),id:\.0) {day,count in HStack{Text(day);Spacer();Text(count.formatted()).monospacedDigit()}.padding(12);Divider()}}.background(.background,in:RoundedRectangle(cornerRadius:12))
    }
    private var modelTable:some View {
        let grouped=Dictionary(grouping:rows,by:{$0.model}).map{key,value in (key,(try? UsageSnapshot.total(value).total) ?? 0)}.sorted{$0.1 > $1.1}
        return VStack(alignment:.leading,spacing:16) {Text("模型用量").font(.headline);ForEach(grouped,id:\.0) {model,count in HStack{Image(systemName:"cpu").foregroundStyle(accent);Text(model).lineLimit(1);Spacer();Text(count.formatted()).monospacedDigit()}.padding(14).background(.background,in:RoundedRectangle(cornerRadius:10))}}
    }
    private func sources(_ snapshot:UsageSnapshot,failedSource:String? = nil)->some View {
        VStack(spacing:14) {ForEach(snapshot.sources) {source in
            VStack(alignment:.leading,spacing:12) {
                HStack {Label(source.source_id,systemImage:"externaldrive").font(.headline);Spacer();Text(source.source_id==failedSource ? "本轮读取失败" : source.status).foregroundStyle(source.source_id==failedSource || source.status != "ok" ? .orange : .green)}
                if source.source_id==failedSource {Text("以下为上次成功快照；本轮整机数据未替换").font(.caption).foregroundStyle(.secondary)}
                Text("文件 \(source.files) · 缓存命中 \(source.cache_hits)").foregroundStyle(.secondary)
                ForEach(source.coverage.keys.sorted().filter{source.coverage[$0,default:0]>0},id:\.self) {key in HStack{Text(coverageLabel(key));Spacer();Text(source.coverage[key,default:0].formatted()).monospacedDigit()}.font(.caption).foregroundStyle(.secondary)}
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:14))
        }}
    }
    private func coverageLabel(_ key:String)->String {
        ["input_reclassifications":"已确认的输入缓存拆分", "deduplicated_symlink_files":"已排除重复文件别名", "runtime_usage_records":"仅核对的 Runtime 用量记录", "missing_backend_threads":"缺少专属后端日志", "auxiliary_usage_records":"辅助调用记录", "residual_usage_records":"主调用未覆盖残差", "negative_residual_records":"主调用计数冲突", "orphan_usage_records":"缺少会话关联", "usage_records":"观测用量记录", "response_usage_records":"Response 用量记录", "mirrored_usage_records":"已排除重复镜像", "context_estimate_records":"上下文估算记录", "unknown_model_records":"模型未明确的记录", "unmetered_files":"无法恢复用量的文件", "unclassified_usage_records":"未分类用量记录", "invalid_cache_ttl_records":"缓存计数冲突", "missing_time_records":"缺少可靠时间", "missing_identity_records":"缺少调用标识", "ambiguous_time_records":"时间关联冲突", "unsupported_fields":"未知字段观测", "counter_resets":"累计计数回退", "streaming_regressions":"乱序流式更新", "unclassified_fork_prefix_records":"归属未明的历史前缀", "unallocated_tokens":"未分摊 Token", "pending_files":"等待末行写完的文件"][key] ?? "其他覆盖诊断"
    }
    private var settingsSheet:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("采集连接").font(.title2.bold())
            Text("只运行明确选择的 collector，不启动登录、在线额度或自动更新。").foregroundStyle(.secondary)
            Text("多机模式选择机器清单配置；单机模式选择来源配置。").font(.caption).foregroundStyle(.secondary)
            Toggle("多机汇总模式",isOn:Binding(get:{store.draft.fleetMode == true},set:{store.draft.fleetMode=$0}))
            Toggle("每 5 分钟自动刷新",isOn:Binding(get:{store.draft.autoRefresh != false},set:{store.draft.autoRefresh=$0}))
            pathField("Collector 程序",path:$store.draft.executable,directory:false)
            pathField("私有配置 JSON",path:$store.draft.configuration,directory:false)
            HStack {Spacer();Button("取消"){store.settingsOpen=false};Button("保存并采集"){if store.saveSettings() {store.settingsOpen=false;store.refresh()}}.buttonStyle(.borderedProminent).disabled(store.busy)}
        }.padding(28).frame(width:600)
    }
    private func pathField(_ title:String,path:Binding<String>,directory:Bool)->some View {
        VStack(alignment:.leading,spacing:6) {Text(title).font(.callout.weight(.medium));HStack{TextField(title,text:path);Button("选择…"){let panel=NSOpenPanel();panel.canChooseDirectories=directory;panel.canChooseFiles = !directory;panel.allowsMultipleSelection=false;if panel.runModal() == .OK,let url=panel.url {path.wrappedValue=url.path}}}}
    }
}
