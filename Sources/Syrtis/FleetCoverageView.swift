import SwiftUI
import UsageCore

struct FleetCoverageView: View {
    let report: CoverageReport
    @SyrtisState private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("以下诊断涵盖所选机器的全部来源和日期，不随图表的 Agent、模型或日期筛选缩小。同步成功不代表历史用量完整。")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(report.unavailableHosts, id: \.self) { host in
                    Text("\(host)：尚无当前配置的可用快照").font(.caption).foregroundStyle(.orange)
                }
                ForEach(report.sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(source.host) / \(source.source)").font(.caption.bold())
                        Text(source.statusLabel + (source.retained ? " · 上次成功快照" : ""))
                            .font(.caption).foregroundStyle(source.hasGap || source.retained ? Color.orange : Color.secondary)
                        Text("来源文件：\(source.files)").font(.caption2).foregroundStyle(.secondary)
                        ForEach(source.details) { detail in
                            HStack(alignment: .top) {
                                Text(detail.title)
                                Spacer()
                                Text(detail.count.formatted()).monospacedDigit()
                            }.font(.caption2).foregroundStyle(detail.isGap ? Color.orange : Color.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                if report.available && report.current && !report.complete && !report.sources.contains(where: \.hasGap) {
                    Text("来源报告覆盖不完整；当前快照未提供更细的缺口原因。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }.padding(.top, 6)
        } label: {
            Label(report.title, systemImage: report.complete ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption).foregroundStyle(report.complete ? Color.secondary : Color.orange)
        }
    }
}
