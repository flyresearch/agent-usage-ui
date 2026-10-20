import AppKit
import SwiftUI
import TokenBarCore
import UsageCore

/// The native dashboard shares the fleet bridge's sanitized statusLine format.
/// No account identity can be inferred from a session observation.
enum NativeClaudeBridge {
    static let enabledKey = "agentusage.nativeClaudeBridge.enabled"
    static let pathKey = "agentusage.nativeClaudeBridge.path"
    struct Configuration: Sendable {
        var enabled: Bool
        var path: String
    }
    private struct LegacyConfiguration: Decodable {
        let claudeQuotaEnabled: Bool?
        let claudeQuotaSnapshot: String?
    }
    static func configuration(defaults: UserDefaults = .standard, connection: URL? = nil) throws -> Configuration {
        if let enabled = defaults.object(forKey: enabledKey) as? Bool {
            return Configuration(enabled: enabled, path: defaults.string(forKey: pathKey) ?? "")
        }
        let url = connection ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentUsageOffline/connection.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Configuration(enabled: true, path: "")
        }
        let legacy = try JSONDecoder().decode(LegacyConfiguration.self, from: Data(contentsOf: url))
        return Configuration(enabled: legacy.claudeQuotaEnabled == true, path: legacy.claudeQuotaSnapshot ?? "")
    }

    static func replacingClaude(
        in payload: AgentUsagePayload,
        configuration load: () throws -> Configuration = { try configuration() },
        now: Date = Date()
    ) async throws -> AgentUsagePayload {
        var agents = payload.agents.filter { $0.clientId != "claude" }
        var snapshot: NativeQuotaSnapshot?
        var message: String?
        do {
            let config = try load()
            guard config.enabled else { return payload.replacingAgents(agents) }
            if config.path.isEmpty {
                message = "Claude 会话额度尚未配置：请在设置中选择 statusLine 额度快照。"
            } else {
                // Same bounded, freshness-checked decoder as fleet scope.
                snapshot = try ClaudeQuota.fetch(path: config.path, now: now)
                if snapshot?.coverageComplete == false {
                    snapshot = nil
                    message = "Claude 会话尚未提供完整的五小时和七天额度窗口。"
                } else if snapshot?.remaining(at: now) == nil {
                    snapshot = nil
                    message = "Claude 会话额度已过期，等待新的 statusLine 观测。"
                }
            }
        } catch NativeQuotaError.staleSample {
            message = "Claude 会话额度已过期，等待新的 statusLine 观测。"
        } catch NativeQuotaError.missingSample {
            message = "尚无 Claude 会话额度观测；请等待 Claude Code 输出 statusLine。"
        } catch {
            message = "无法读取 Claude 会话额度配置或快照；未查询登录凭据。"
        }
        if let snapshot {
            let projected = try await FleetUsageDataSource.shared.projectQuotas([(.claude, true, snapshot)], now: now)
            agents.append(contentsOf: projected.agents)
        } else {
            let entry: [String: Any] = [
                "clientId": "claude", "source": "native-statusline",
                "updatedAt": ISO8601DateFormatter().string(from: now),
                "windows": [], "error": message ?? "Claude 会话额度不可用。"
            ]
            agents.append(try JSONDecoder().decode(AgentUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: entry)))
        }
        return payload.replacingAgents(agents)
    }


}

struct NativeClaudeBridgeSettings: View {
    @SyrtisState private var config = NativeClaudeBridge.Configuration(enabled: false, path: "")
    @SyrtisState private var loaded = false
    @SyrtisState private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("本机 Claude 会话额度", isOn: Binding(get: { config.enabled }, set: { config.enabled = $0; save() }))
            Text("仅接收 Claude Code statusLine 的五小时和七天额度，不读取登录凭据，不调用 OAuth 或发送模型探针。样本超过九十秒即过期；不提供账号归属、模型专属额度或账号历史曲线。")
                .font(.caption2).foregroundStyle(.secondary)
            if config.enabled {
                HStack {
                    Text(config.path.isEmpty ? "未选择额度快照" : URL(fileURLWithPath: config.path).lastPathComponent)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("选择快照…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { config.path = url.path; save() }
                    }
                }
                Text("沿用已配置的多机 statusLine 桥接；此处另选文件后只影响本机模式。需由 Claude Code 会话生成新的观测。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if failed { Text("无法读取桥接配置，请重新选择快照。保存会仅更新本机桥接偏好。").font(.caption).foregroundStyle(.orange) }
        }
        .disabled(!loaded)
        .task {
            guard !DemoData.ignoresLocalVisibility else { return }
            do { config = try NativeClaudeBridge.configuration() } catch { failed = true }
            loaded = true
        }
    }
    private func save() {
        UserDefaults.standard.set(config.path, forKey: NativeClaudeBridge.pathKey)
        UserDefaults.standard.set(config.enabled, forKey: NativeClaudeBridge.enabledKey)
        failed = false
    }
}

extension NativeClaudeBridge {
    /// Exercises the shipped file reader, decoder and replacement path with
    /// synthetic files, including an old OAuth card that must never survive.
    static func check() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = root.appendingPathComponent("quota.json")
        let payload = try JSONDecoder().decode(AgentUsagePayload.self, from: Data(#"{"generatedAt":"2027-01-15T08:00:00Z","agents":[{"clientId":"claude","source":"oauth","accountKey":"old-account","updatedAt":"2027-01-15T08:00:00Z","windows":[]},{"clientId":"codex","source":"oauth","updatedAt":"2027-01-15T08:00:00Z","windows":[]}]}"#.utf8))
        func write(_ age: Double, partial: Bool = false) throws {
            let windows: [[String: Any]] = [
                ["window": "five_hour", "used_percentage": 25, "resets_at": now.timeIntervalSince1970 + 3600],
                ["window": "seven_day", "used_percentage": 50, "resets_at": now.timeIntervalSince1970 + 86400]
            ]
            try JSONSerialization.data(withJSONObject: ["schema_version": 1, "captured_at": now.timeIntervalSince1970 - age, "windows": partial ? Array(windows.prefix(1)) : windows]).write(to: sample)
        }
        let config = Configuration(enabled: true, path: sample.path)
        try write(0)
        let fresh = try await replacingClaude(in: payload, configuration: { config }, now: now)
        guard fresh.agents.count == 2, fresh.agents[0].clientId == "codex",
              fresh.agents[1].source == "native-statusline", fresh.agents[1].accountKey == nil,
              fresh.agents[1].windows.count == 2, fresh.agents[1].windows[0].usedPercent == 25,
              fresh.agents[1].error == nil else { throw FleetSourceError.unavailable }
        try write(91)
        let stale = try await replacingClaude(in: fresh, configuration: { config }, now: now)
        guard stale.agents.last?.windows.isEmpty == true, stale.agents.last?.error?.contains("过期") == true else { throw FleetSourceError.unavailable }
        try write(0, partial: true)
        let partial = try await replacingClaude(in: payload, configuration: { config }, now: now)
        guard partial.agents.last?.error?.contains("完整") == true else { throw FleetSourceError.unavailable }
        try Data("not-json".utf8).write(to: sample)
        let malformed = try await replacingClaude(in: payload, configuration: { config }, now: now)
        guard malformed.agents.last?.windows.isEmpty == true, malformed.agents.last?.error != nil else { throw FleetSourceError.unavailable }
        try FileManager.default.removeItem(at: sample)
        let missing = try await replacingClaude(in: payload, configuration: { config }, now: now)
        guard missing.agents.last?.error?.contains("尚无") == true else { throw FleetSourceError.unavailable }
        let disabled = try await replacingClaude(in: payload, configuration: { Configuration(enabled: false, path: sample.path) }, now: now)
        guard disabled.agents.count == 1, disabled.agents[0].clientId == "codex" else { throw FleetSourceError.unavailable }
        let badConfig = try await replacingClaude(in: payload, configuration: { throw FleetSourceError.unavailable }, now: now)
        guard badConfig.agents.last?.source == "native-statusline", badConfig.agents.last?.windows.isEmpty == true else { throw FleetSourceError.unavailable }
        let suite = "agent-usage-claude-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = root.appendingPathComponent("connection.json")
        try Data(#"{"claudeQuotaEnabled":true,"claudeQuotaSnapshot":"/synthetic/quota.json"}"#.utf8).write(to: connection)
        guard try configuration(defaults: defaults, connection: connection).path == "/synthetic/quota.json" else { throw FleetSourceError.unavailable }
        defaults.set(false, forKey: enabledKey)
        guard try !configuration(defaults: defaults, connection: connection).enabled else { throw FleetSourceError.unavailable }
    }
}
