import SwiftUI
import TokenBarCore

/// "Agents by cost" lens, port of AgentsView.tsx: named sub-agents (plus a
/// "Main" bucket for unattributed messages) ranked by cost, showing the
/// source clients they ran under, message count, total tokens, and cost.
struct AgentsView: View {
    let report: AgentsReport?
    /// Restrict to agents that ran under any of these clients; empty = all.
    var clientIds: [String] = []
    var loading = false

    var body: some View {
        let allow = Set(clientIds)
        let rows = (report?.entries ?? [])
            .filter { $0.clients.contains { allow.contains($0) } }
            .sorted { FleetMode.enabled ? $0.total > $1.total : $0.cost > $1.cost }
        let totalCost = rows.reduce(0) { $0 + $1.cost }
        let totalTokens = rows.reduce(Int64(0)) { $0.saturatingAdding($1.total) }
        let maximum = FleetMode.enabled ? max(Double(rows.map(\.total).max() ?? 0),1) : max(rows.map(\.cost).max() ?? 1,0.000001)

        DashCard(
            FleetMode.enabled ? "主／子代理用量" : "Agents by cost",
            trailing: {
                Text((rows.count == 1 ? "%lld agent · %@" : "%lld agents · %@")
                    .localized(rows.count, FleetMode.enabled ? Format.compactTokens(totalTokens)+" Token" : Format.usd(totalCost)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        ) {
            if FleetMode.enabled {
                Text("仅按明确元数据区分主／子代理；未提供归属的用量单列，不推断代理名称。金额为目录价估算。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if report == nil {
                if FleetMode.enabled && !loading {Text("代理数据暂不可用，请刷新。").font(.caption).foregroundStyle(.secondary)}
                else {LoadingLine(title: "Loading…")}
            } else if rows.isEmpty {
                Text("No agent activity in this range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(rows, id: \.agent) { entry in
                        row(entry, totalCost: FleetMode.enabled ? Double(totalTokens) : totalCost, maxCost: maximum)
                    }
                }
            }
        }
    }

    private func row(_ entry: AgentReportEntry, totalCost: Double, maxCost: Double) -> some View {
        let metric = FleetMode.enabled ? Double(entry.total) : entry.cost
        let share = totalCost > 0 ? metric / totalCost * 100 : 0
        let sources = entry.clients.map { ClientRegistry.style($0).displayName }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(FleetMode.enabled ? (["main":"主代理","subagent":"子代理","unknown":"未提供归属"][entry.agent] ?? "未提供归属") : entry.agent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.agent)
                Spacer()
                Text(String(format: "%.1f%%", share))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary.opacity(0.5))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(metric / maxCost))
                }
            }
            .frame(height: 6)
            HStack {
                Text(sources)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(sources)
                Spacer()
                Text(FleetMode.enabled
                     ? "已计量 \(entry.messages.formatted())\(entry.messageCountComplete == true ? "" : "（部分）") · \(Format.compactTokens(entry.total)) Token · " + (entry.costEstimate.map { Format.usd($0) } ?? "金额 —")
                     : "%@ msgs".localized(entry.messages.formatted()) + " · \(Format.compactTokens(entry.total)) · \(Format.money(tokens:entry.total,cost:entry.cost))")
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
            .font(.caption2)
        }
    }
}
