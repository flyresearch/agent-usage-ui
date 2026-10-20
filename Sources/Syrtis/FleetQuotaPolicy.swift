import Foundation
import TokenBarCore

/// Apply the native bridges' freshness contract at presentation time, including
/// when the popover is closed. Never reuse the legacy persisted scalar.
enum FleetQuotaPolicy {
    static let historyVisibleKey = "agentusage.quota.historyVisible"
    static let clients = ["codex", "agy", "claude"]

    /// Display preferences only: collection and retained history are independent.
    static func visibleClients(client: String?, enabled: Bool, tabsHidden: String,
                               limitsHidden: String, order: String) -> [String] {
        guard enabled else { return [] }
        let excluded = ClientRegistry.quotaExcludedClients(
            tabHidden: ClientRegistry.parseIdSet(tabsHidden),
            limitsHidden: ClientRegistry.parseIdSet(limitsHidden))
        return ClientRegistry.orderedClients(client.map { [$0] } ?? clients, orderRaw: order)
            .filter { !excluded.contains($0) }
    }

    static func current(_ payload:AgentUsagePayload?,now:Date=Date()) -> AgentUsagePayload? {
        guard let payload else {return nil}
        return payload.replacingAgents(payload.agents.filter { agent in
            guard agent.error==nil,!agent.windows.isEmpty,
                  let ms=WindowCardLoader.parseISO8601Ms(agent.updatedAt),
                  (-5...90).contains(now.timeIntervalSince1970-Double(ms)/1000) else {return false}
            return agent.windows.allSatisfy { window in
                guard let reset=window.resetsAt else {return true}
                guard let ms=WindowCardLoader.parseISO8601Ms(reset) else {return false}
                return Double(ms)/1000>now.timeIntervalSince1970
            }
        })
    }
}
