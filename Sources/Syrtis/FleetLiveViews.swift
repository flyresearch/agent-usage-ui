import SwiftUI
import Charts
import UsageCore
import TokenBarCore

struct FleetActivityCard: View {
    var clientIds: [String]
    var body: some View {
        TimelineView(.periodic(from:.now,by:5)) { clock in content(now:clock.date) }
    }
    @ViewBuilder private func content(now:Date) -> some View {
        let state=FleetUIState.shared
        DashCard("近期用量速率") {
            if !state.liveEnabled {
                Text("在设置中启用近期 tokens/min 后，约每三十秒刷新。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let report=state.activity,report.available,
                      let sample=report.oldestSample,(-5...75).contains(now.timeIntervalSince(sample)) {
                let clients=report.clients.filter {clientIds.contains($0.agent)}
                let rate=clients.reduce(0.0){$0+Double($1.tokens)}*60/Double(report.windowSeconds)
                Text(String(format:rate<10 ? "%.1f tok/min":"%.0f tok/min",rate)+(report.complete ? "":" · 已知部分"))
                    .font(.title3.monospacedDigit())
                Text("近十分钟已落盘 Token 的平均速率，包含输入、缓存与输出；不是模型生成速度。")
                    .font(.caption2).foregroundStyle(.secondary)
                if let time=report.oldestSample {Text("最早样本："+time.formatted(date:.omitted,time:.standard)).font(.caption2).foregroundStyle(.secondary)}
                if !report.complete {Text("存在未升级、过期或缺少精确事件时间的来源；未覆盖部分没有按零计入。")
                    .font(.caption2).foregroundStyle(.orange)}
                if !report.retainedHosts.isEmpty {
                    Text("部分机器更新失败，当前保留 75 秒内的上次样本："+report.retainedHosts.joined(separator:"、"))
                        .font(.caption2).foregroundStyle(.orange)
                }
                ForEach(clients) { client in
                    HStack {
                        AgentIconView(clientId:client.agent)
                        Text(ClientRegistry.style(client.agent).displayName)
                        Spacer()
                        Text(String(format:"%.0f/m",Double(client.tokens)*60/Double(report.windowSeconds))).monospacedDigit()
                    }.font(.caption)
                }
            } else {
                if let report=state.activity,!report.missingHosts.isEmpty {
                    Text("缺少有效近期样本："+report.missingHosts.joined(separator:"、")).font(.caption).foregroundStyle(.orange)
                }
                Text("近期速率暂不可用；等待新快照或检查采集状态。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct FleetQuotaSection: View {
    var client:String?
    var body:some View {
        if client == nil || client == "codex" {FleetQuotaCard(provider:.codex)}
        if client == nil || client == "agy" {FleetQuotaCard(provider:.agy)}
        if client == nil || client == "claude" {FleetQuotaCard(provider:.claude)}
        if let client,client != "codex",client != "agy",client != "claude" {
            DashCard("在线额度") {Text("此 Agent 尚未接入官方额度接口，请在原应用查看。").font(.caption).foregroundStyle(.secondary)}
        }
    }
}
struct FleetQuotaCard: View {
    let provider:NativeQuotaProvider
    var body: some View {
        TimelineView(.periodic(from:.now,by:5)) { clock in content(now:clock.date) }
            .task {await FleetUsageDataSource.shared.refreshQuota(provider:provider)}
    }
    @ViewBuilder private func content(now:Date) -> some View {
        let state=FleetUIState.shared.quotaState(provider)
        DashCard(provider.title+" 在线额度") {
            VStack(alignment:.leading,spacing:10) {
                if !state.quotaEnabled {
                    Text(provider == .claude ? "在设置中启用 Claude 会话额度，并配置状态栏桥接快照。":"在设置中启用在线额度，并选择已登录的 "+provider.title+" 程序。").font(.caption).foregroundStyle(.secondary)
                } else if state.quotaLoading {
                    ProgressView("正在查询额度…").controlSize(.small)
                } else if let snapshot=state.quota,snapshot.fresh(at:now) {
                    Text(provider == .claude ? "本机最近观测到的 Claude Code 会话额度；不代表独立实时查询，不跨会话或机器相加。":"本机原生 CLI 当前登录账号；不随机器筛选变化，不跨机器相加。菜单栏额度跟随设置中选择的窗口；自动模式选择剩余比例最少的窗口。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !snapshot.coverageComplete {Text("部分窗口未返回可用额度，当前仅显示已知窗口。").font(.caption).foregroundStyle(.orange)}
                    ForEach(snapshot.windows) { window in
                        VStack(alignment:.leading,spacing:4) {
                            Text(window.title + (window.durationMinutes.map { " · "+duration($0) } ?? "" )).font(.caption.bold())
                            if let reset=window.resetsAt,reset <= now {
                                Text("窗口已到重置时间，等待重新获取").font(.caption).foregroundStyle(.orange)
                            } else {
                                ProgressView(value:window.usedPercent,total:100)
                                Text(String(format:"已用 %.1f%% · 剩余 %.1f%%",window.usedPercent,window.remainingPercent))
                                    .font(.caption.monospacedDigit())
                            }
                            Text(window.resetsAt.map {"重置："+$0.formatted(date:.abbreviated,time:.shortened)} ?? "服务端未提供重置时间")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text((provider == .claude ? "观测时间：":"查询时间：")+snapshot.capturedAt.formatted(date:.omitted,time:.standard)).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(state.quotaMessage ?? "额度数据已过期或尚未获取，请刷新。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if state.quotaEnabled {
                    Divider()
                    FleetQuotaHistoryView(points:state.history,provider:provider,snapshot:state.quota,now:now)
                    if let notice=state.historyMessage {Text(notice).font(.caption2).foregroundStyle(.orange)}
                }
                Group {
                    Button(provider == .claude ? "重新读取快照":"刷新额度") {Task {await FleetUsageDataSource.shared.refreshQuota(provider:provider,force:true)}}
                        .disabled(!state.quotaEnabled || state.quotaLoading)
                    Text(provider == .claude ? "读取官方 statusLine 输出的额度字段；首次会话响应后才可能提供。重复回调不会延长有效期，不读取登录票据。":"仅通过原生 CLI 的官方只读接口查询；不创建模型轮次，不保存登录票据。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func duration(_ minutes:Int) -> String {
        if minutes%1440==0 {return "\(minutes/1440) 天"}
        if minutes%60==0 {return "\(minutes/60) 小时"}
        return "\(minutes) 分钟"
    }
}


struct FleetQuotaHistoryView: View {
    let points:[QuotaObservation]
    let provider:NativeQuotaProvider
    let snapshot:NativeQuotaSnapshot?
    let now:Date
    @SyrtisState private var days=1
    @SyrtisState private var selectedWindow=""
    var body:some View {
        let report=QuotaHistoryPresentation(points:points,selectedWindow:selectedWindow,days:days,now:now)
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("额度历史").font(.caption.bold())
                Spacer()
                HStack(spacing:2) {
                    ForEach([1,7],id:\.self) { value in
                        Button {days=value} label: {
                            Text(value==1 ? "24 小时":"7 天")
                                .font(.caption.weight(days==value ? .semibold:.regular))
                                .padding(.horizontal,9).padding(.vertical,5)
                                .background(days==value ? Color.accentColor.opacity(0.14):Color.clear,in:RoundedRectangle(cornerRadius:5))
                        }.buttonStyle(.plain)
                        .accessibilityAddTraits(days==value ? .isSelected:[])
                    }
                }.padding(2).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:7))
            }
            if points.isEmpty {
                Text("尚无历史观测；从启用后开始记录，不回填过去数据。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                FlowLayout(hSpacing:6,vSpacing:4) {
                    ForEach(report.windowIDs,id:\.self) { id in
                        Button {selectedWindow=id} label: {
                            Text(report.titles[id] ?? "额度窗口")
                                .font(.caption2.weight(report.selectedWindow==id ? .semibold:.regular))
                                .padding(.horizontal,7).padding(.vertical,5)
                                .foregroundStyle(report.selectedWindow==id ? Color.accentColor:Color.secondary)
                                .background(report.selectedWindow==id ? Color.accentColor.opacity(0.12):Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:5))
                        }.buttonStyle(.plain).accessibilityAddTraits(report.selectedWindow==id ? .isSelected:[])
                    }
                }
                if report.visible.isEmpty {
                    Text("所选时间范围内没有观测。").font(.caption).foregroundStyle(.secondary)
                } else {
                    FleetQuotaHistoryChart(points:report.plotted).equatable()
                    Text("\(report.visible.count) 次观测 · 最近 "+report.visible.last!.time.formatted(date:.abbreviated,time:.shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let snapshot,snapshot.fresh(at:now),
                   let last=report.visible.last,last.time==snapshot.capturedAt,
                   let trend=report.trend {
                    Text(String(format:"近期净增 %.1f 个百分点／小时",trend.percentagePointsPerHour))
                        .font(.caption.monospacedDigit())
                    if last.used>=100 {
                        Text("当前观测额度已用尽。").font(.caption2).foregroundStyle(.orange)
                    } else if trend.percentagePointsPerHour==0 {
                        Text("近期未观察到额度比例净增长，暂不估算耗尽时间。").font(.caption2).foregroundStyle(.secondary)
                    } else if let exhaustion=trend.exhaustedAt {
                        Text("按近期变化估算，可能于 "+exhaustion.formatted(date:.omitted,time:.shortened)+" 耗尽；非服务端预测。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("按近期变化推算，未预计在当前重置时间前耗尽。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text(provider == .codex ? "趋势需完整窗口信息及至少 3 个同账号、同窗口的连续样本，跨度满 5 分钟；中断后重新积累。":"账号连续性尚未确认，仅显示观测点，不推算消耗速度或耗尽时间。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("仅保留本机最近 7 天观测。账号变化、重置、回落、重启及采集中断分段显示，不跨段推算。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}


/// Clock ticks update stale labels but do not rebuild an unchanged chart.
private struct FleetQuotaHistoryChart: View, Equatable {
    let points:[QuotaObservation]
    var body:some View {
                    Chart(points) { point in
                        if point.continuous {
                            LineMark(x:.value("时间",point.time),y:.value("已用百分比",point.used),series:.value("连续采集段",point.segment))
                                .foregroundStyle(Color.accentColor.opacity(0.75))
                        }
                        PointMark(x:.value("时间",point.time),y:.value("已用百分比",point.used))
                            .foregroundStyle(Color.accentColor).symbolSize(12)
                    }
                    .chartYScale(domain:0...100)
                    .chartYAxis {AxisMarks(values:[0,50,100]) { value in
                        AxisGridLine();AxisValueLabel {if let v=value.as(Int.self) {Text("\(v)%")}}
                    }}
                    .chartXAxis {AxisMarks(values:.automatic(desiredCount:3))}
                    .chartLegend(.hidden).frame(height:115)

    }
}
