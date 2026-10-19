import Foundation

/// Host/source diagnostics retain their original all-date scope. Filtering chart
/// rows cannot establish coverage for a date or a client with no metered rows.
public struct CoverageDiagnostic: Identifiable, Sendable {
    public let key: String
    public let title: String
    public let count: UInt64
    public let isGap: Bool
    public var id: String { key }
}
public struct SourceDiagnostic: Identifiable, Sendable {
    public let host: String
    public let source: String
    public let status: String
    public let retained: Bool
    public let failed: Bool
    public let files: UInt64
    public let details: [CoverageDiagnostic]
    public var id: String { host + "|" + source }
    public var hasGap: Bool { failed || ["partial", "unmetered"].contains(status) || details.contains(where: \.isGap) }
    public var statusLabel: String {
        if failed { return "本轮读取失败" }
        if hasGap { return status == "unmetered" ? "用量未计量" : "覆盖不完整" }
        return status == "empty" ? "未找到来源文件" : "未发现已知覆盖缺口"
    }
}
public struct CoverageReport: Sendable {
    public let available: Bool
    public let complete: Bool
    public let current: Bool
    public let sources: [SourceDiagnostic]
    public let unavailableHosts: [String]
    public var title: String {
        if !available { return "尚无当前配置的用量快照" }
        if !current { return "部分机器未同步，当前结果可能包含旧快照" }
        return complete ? "未发现已知覆盖缺口" : "用量覆盖不完整"
    }
    public init(fleet: FleetSnapshot?, snapshot: UsageSnapshot?, host: String? = nil, refreshFailed: Bool = false) {
        var diagnostics = [SourceDiagnostic]()
        var available = false, complete = true, current = !refreshFailed
        var missing = [String]()
        func append(_ snapshot: UsageSnapshot, retained: Bool, failed: String?) {
            available = true
            complete = complete && snapshot.coverage_complete
            for source in snapshot.sources {
                let details = source.coverage.filter { $0.value > 0 }.map { key, count in
                    let known = Self.labels[key]
                    return CoverageDiagnostic(key: key, title: known?.0 ?? "其他来源诊断", count: count,
                                              isGap: known?.1 ?? true)
                }.sorted { a, b in a.isGap != b.isGap ? a.isGap : a.key < b.key }
                diagnostics.append(SourceDiagnostic(host: snapshot.host_id, source: source.source_id,
                    status: source.status, retained: retained, failed: source.source_id == failed,
                    files: source.files, details: details))
            }
        }
        if let fleet {
            let hosts = fleet.hosts.filter { host == nil || $0.host_id == host }
            if hosts.isEmpty { complete = false; current = false }
            for h in hosts {
                current = current && h.state == "fresh"
                if h.included, let s = h.snapshot { append(s, retained: h.state != "fresh" || refreshFailed, failed: h.failed_source_id) }
                else { missing.append(h.host_id); complete = false }
            }
        } else if let snapshot, host == nil || host == snapshot.host_id {
            append(snapshot, retained: refreshFailed, failed: nil)
        } else { complete = false; current = false }
        self.available = available
        self.current = current
        self.complete = available && complete && current && !diagnostics.contains(where: \.hasGap)
        self.sources = diagnostics
        self.unavailableHosts = missing
    }
    private static let labels: [String: (String, Bool)] = [
        "unclassified_usage_records": ("未计量或未分类的响应", true),
        "unmetered_files": ("无法恢复用量的文件", true),
        "missing_backend_threads": ("缺少专属后端日志", true),
        "negative_residual_records": ("主调用计数冲突", true),
        "orphan_usage_records": ("缺少会话关联", true),
        "missing_identity_records": ("缺少调用标识", true),
        "ambiguous_time_records": ("时间关联冲突", true),
        "invalid_cache_ttl_records": ("缓存计数冲突", true),
        "unclassified_fork_prefix_records": ("归属未明的历史前缀", true),
        "pending_files": ("等待末行写完的文件", true),
        "unknown_total_carry": ("无法分类的累计 Token", true),
        "missing_time_records": ("缺少可靠时间的记录", true),
        "unknown_model_records": ("模型未明确的记录", true),
        "unsupported_fields": ("尚未支持的用量字段", true),
        "counter_resets": ("累计计数回退", true),
        "unallocated_tokens": ("未分摊日期的 Token", true),
        "usage_records": ("观测用量记录（去重前）", false),
        "response_usage_records": ("响应用量记录", false),
        "mirrored_usage_records": ("已排除的用量镜像", false),
        "deduplicated_symlink_files": ("已排除的文件别名", false),
        "input_reclassifications": ("已确认的输入缓存拆分", false),
        "runtime_usage_records": ("仅用于核对的 Runtime 记录", false),
        "auxiliary_usage_records": ("辅助调用记录", false),
        "residual_usage_records": ("主调用未覆盖残差", false),
        "context_estimate_records": ("上下文估算记录", false),
        "streaming_regressions": ("已识别的乱序流式更新", false)
    ]
}
