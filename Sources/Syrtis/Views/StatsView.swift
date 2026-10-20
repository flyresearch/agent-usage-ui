import SwiftUI
import TokenBarCore
import UsageCore

/// "Stats" lens, port of StatsView.tsx: the usage chart over a headline
/// summary — total spend, six metric cells, favorite model and best day —
/// distilled from the same stats and model report the other lenses use.
struct StatsView: View {
    let payload: UsagePayload
    /// The active tab's client slice.
    let clientIds: [String]
    let stats: UsageStats
    let modelReport: ModelReport?
    /// The year `modelReport` was fetched for, in identity form.
    var modelYear: String?
    let colors: ModelColorMap
    /// Dashboard year filter (nil = all time), forwarded to the chart card.
    var year: String?
    /// The client tab this slice belongs to, or nil on Overview. Passed
    /// explicitly rather than inferred from `clientIds.count == 1`, because
    /// Overview legitimately displays exactly one client when the others are
    /// hidden or absent.
    var singleClient: String?
    /// Forwarded to the attribution card so a terminal nil report reads as
    /// unavailable rather than as a request still in flight.
    var reportLoading = false

    @AppStorage("agentusage.selectedHost") private var selectedHost=""
    @SyrtisState private var offlineReport:FleetHeaderReport?
    @SyrtisState private var offlineReportKey:FleetHeaderKey?

    private var favorite: ModelReportEntry? {
        let allow = Set(clientIds)
        return (modelReport?.modelLevelEntries ?? [])
            .filter { allow.contains($0.client) }
            .max { FleetMode.enabled ? $0.total < $1.total : $0.cost < $1.cost }
    }

    var body: some View {
        let state=FleetUIState.shared
        let configuration=state.fleet?.configuration_fingerprint ?? state.local.map{$0.host_id+"|"+$0.configuration_fingerprint}
        let available=state.fleet?.hasData(host:selectedHost.isEmpty ? nil:selectedHost) ?? (state.local != nil)
        let key=FleetHeaderKey(revision:state.revision,host:selectedHost,clients:clientIds.sorted(),year:year,configuration:configuration,available:available)
        let report=(offlineReportKey==key || key.canRetain(offlineReportKey)) ? offlineReport:nil
        VStack(spacing: 12) {
            UsageChartCard(
                payload: payload, clientIds: clientIds, stats: stats, colors: colors,
                year: year)
            summaryCard(report)
            if !FleetMode.enabled { UsageAttributionBreakdownCard(
                report: modelReport, reportYear: modelYear, clientIds: clientIds,
                singleClient: singleClient, reportLoading: reportLoading) }
        }
        .task(id:key) {
            guard FleetMode.enabled else {return}
            let value=await FleetPresentation.shared.header(fleet:state.fleet,local:state.local,host:key.host,clients:key.clients,year:key.year)
            guard !Task.isCancelled,state.revision==key.revision else {return}
            offlineReport=value;offlineReportKey=key
        }
    }

    private func summaryCard(_ report:FleetHeaderReport?) -> some View {
        let offlineCost=report?.cost.map { "≈" + Format.usd($0) + (report?.costComplete == true ? "":"（部分已定价）") } ?? "—"
        let offlineTotal=report?.total.map { $0.formatted(.number.notation(.compactName)) } ?? "—"
        return VStack(alignment: .leading, spacing: 12) {
            if FleetMode.enabled {
                Text("目录价估算：" + offlineCost).font(.system(size:14,weight:.semibold))
            } else {
                (Text("Your total spending is ") + Text(Format.usd(stats.totalCost)).bold().foregroundStyle(Color(hex:"#22c55e"))).font(.system(size:14))
            }
            let metrics: [(label:String,value:String,accent:Bool)] = [
                (FleetMode.enabled ? "已知 Token" : "Total tokens", FleetMode.enabled ? offlineTotal : Format.compactTokens(stats.totalTokens), false),
                (FleetMode.enabled ? "目录价估算" : "Total spend", FleetMode.enabled ? offlineCost : Format.usd(stats.totalCost), true),
                ("Active days",String(stats.activeDays),false),
                (FleetMode.enabled ? "日均 Token（有记录日）" : "Avg / day", FleetMode.enabled ? (stats.activeDays>0 ? Format.compactTokens(stats.totalTokens/Int64(stats.activeDays)):"—") : Format.usd(stats.averagePerDay),false),
                ("Current streak", "%lldd".localized(stats.streaks.current),false),
                ("Longest streak", "%lldd".localized(stats.streaks.longest),false)
            ]
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                spacing: 10
            ) {
                ForEach(metrics, id: \.label) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.value)
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(m.accent ? AnyShapeStyle(Color(hex: "#22c55e")) : AnyShapeStyle(.primary))
                        Text(m.label.localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                if let favorite {
                    HStack {
                        Text(FleetMode.enabled ? "用量最多的模型" : "Favorite model")
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: colors.color(favorite.provider, favorite.model)))
                                .frame(width: 7, height: 7)
                            Text(favorite.model)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                }
                if FleetMode.enabled, let busiest = stats.perDay.max(by: {$0.tokens < $1.tokens}) {
                    HStack {
                        Text("用量最高日").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Format.monthDay(busiest.date)) · \(Format.compactTokens(busiest.tokens)) Token")
                    }.font(.caption)
                }
                if !FleetMode.enabled, let bestDay = stats.bestDay {
                    HStack {
                        Text("Best day")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Format.monthDay(bestDay.date)) · \(Format.usd(bestDay.cost))")
                    }
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .glassCard()
    }
}
