import Foundation
import TokenBarCore

/// Deterministic, synthetic check: an old host's suspended analysis must not
/// replace the new host's report after scope reset, even for identical clients.
enum FleetAnalysisCheck {
    static func run(oldHours: HourlyReport, newHours: HourlyReport,
                    oldAgents: AgentsReport, newAgents: AgentsReport) async throws {
        let source = AnalysisGate(oldHours: oldHours, newHours: newHours, oldAgents: oldAgents, newAgents: newAgents)
        let model = await DashboardModel(source: source)
        let oldHour = Task { await model.ensureData(for: .hourly, clients: ["codex"]) }
        try await source.started(hour: true)
        await model.resetFleetAnalysis()
        await model.ensureData(for: .hourly, clients: ["codex"])
        await source.release(hour: true)
        await oldHour.value
        let hours = await model.hourlyReport(for: ["codex"])
        guard hours?.entries.first?.total == newHours.entries.first?.total else { throw FleetSourceError.unavailable }

        let oldAgent = Task { await model.ensureData(for: .agents, clients: ["codex"]) }
        try await source.started(hour: false)
        await model.resetFleetAnalysis()
        await model.ensureData(for: .agents, clients: ["codex"])
        await source.release(hour: false)
        await oldAgent.value
        let agents = await model.agents
        guard agents?.entries.first?.total == newAgents.entries.first?.total else { throw FleetSourceError.unavailable }
    }
}
private actor AnalysisGate: UsageDataSource {
    nonisolated let allowsQuotaCachePersistence = false
    let oldHours: HourlyReport
    let newHours: HourlyReport
    let oldAgents: AgentsReport
    let newAgents: AgentsReport
    var hourWait: CheckedContinuation<HourlyReport, Never>?
    var agentWait: CheckedContinuation<AgentsReport, Never>?
    var hourCalls = 0
    var agentCalls = 0
    init(oldHours: HourlyReport, newHours: HourlyReport, oldAgents: AgentsReport, newAgents: AgentsReport) {
        self.oldHours=oldHours;self.newHours=newHours;self.oldAgents=oldAgents;self.newAgents=newAgents
    }
    func started(hour: Bool) async throws {
        let start=ProcessInfo.processInfo.systemUptime
        while hour ? hourWait == nil : agentWait == nil {
            guard ProcessInfo.processInfo.systemUptime-start < 5 else {throw FleetSourceError.unavailable}
            await Task.yield()
        }
    }
    func release(hour: Bool) {
        if hour {hourWait?.resume(returning:oldHours);hourWait=nil}
        else {agentWait?.resume(returning:oldAgents);agentWait=nil}
    }
    func hourlyReport(year: String?, clients: [String]?, priority: TaskPriority) async throws -> HourlyReport {
        hourCalls += 1
        if hourCalls == 1 {return await withCheckedContinuation {hourWait=$0}}
        return newHours
    }
    func agentsReport(year: String?, clients: [String]?, priority: TaskPriority) async throws -> AgentsReport {
        agentCalls += 1
        if agentCalls == 1 {return await withCheckedContinuation {agentWait=$0}}
        return newAgents
    }
    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {throw FleetSourceError.unsupported}
    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {throw FleetSourceError.unsupported}
    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {throw FleetSourceError.unsupported}
    func agentUsage() async throws -> AgentUsagePayload {throw FleetSourceError.unsupported}
    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {throw FleetSourceError.unsupported}
    func tokensPerMin() async throws -> Double {throw FleetSourceError.unsupported}
}
