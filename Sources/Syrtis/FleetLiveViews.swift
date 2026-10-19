import SwiftUI
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
        if let client,client != "codex",client != "agy" {
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
                    Text("在设置中启用在线额度，并选择已登录的 "+provider.title+" 程序。").font(.caption).foregroundStyle(.secondary)
                } else if state.quotaLoading {
                    ProgressView("正在查询额度…").controlSize(.small)
                } else if let snapshot=state.quota,snapshot.fresh(at:now) {
                    Text("本机原生 CLI 当前登录账号；不随机器筛选变化，不跨机器相加。菜单栏额度为 Codex 最紧窗口的剩余比例。")
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
                    Text("查询时间："+snapshot.capturedAt.formatted(date:.omitted,time:.standard)).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(state.quotaMessage ?? "额度数据已过期或尚未获取，请刷新。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Group {
                    Button("刷新额度") {Task {await FleetUsageDataSource.shared.refreshQuota(provider:provider,force:true)}}
                        .disabled(!state.quotaEnabled || state.quotaLoading)
                    Text("仅通过原生 CLI 的官方只读接口查询；不创建模型轮次，不保存登录票据。")
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
