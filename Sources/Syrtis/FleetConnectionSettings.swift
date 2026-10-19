import AppKit
import SwiftUI
import UsageCore

struct FleetConnectionSettings: View {
    @SyrtisState private var draft = ConfigurationDraft(settings: CollectorSettings(executable: "", configuration: "", stateDirectory: "", fleetMode: true))
    @SyrtisState private var original: Data?
    @SyrtisState private var ready = false
    @SyrtisState private var busy = false
    @SyrtisState private var message = ""
    private var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentUsageOffline") }
    private var connection: URL { root.appendingPathComponent("connection.json") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("机器与数据来源").font(.headline)
            Text("只读取你选择的日志或数据库。保存前会试采集；现有配置和统计库保留，检测失败不会切换连接。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("导入现有配置…") { choose(directory: false) { path in loadImport(path) } }
                Button("重新载入") { load() }
                Button("新建配置") { newDraft() }
                Button("恢复连接备份…") { choose(directory: false) { path in loadImport(path) } }
            }
            pathField("汇总采集器", path: $draft.settings.executable, directory: false)
            Toggle("多机汇总", isOn: Binding(get: { draft.settings.fleetMode == true }, set: { draft.settings.fleetMode = $0 }))
            Toggle("自动采集（常规五分钟，速率启用后约三十秒）", isOn: Binding(get: { draft.settings.autoRefresh != false }, set: { draft.settings.autoRefresh = $0 }))
            Toggle("启用近期 tokens/min",isOn:Binding(get:{draft.settings.liveMetrics == true},set:{draft.settings.liveMetrics=$0}))
            Text("按最近十分钟已落盘的 Token 计算平均速率，包含输入、缓存与输出；不是模型生成速度。采集失败或超过 75 秒未更新时不显示为零。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("启用 Codex 在线额度",isOn:Binding(get:{draft.settings.codexQuotaEnabled == true},set:{draft.settings.codexQuotaEnabled=$0}))
            if draft.settings.codexQuotaEnabled == true {
                pathField("Codex CLI 程序",path:Binding(get:{draft.settings.codexExecutable ?? ""},set:{draft.settings.codexExecutable=$0}),directory:false)
                Text("独立每六十秒通过本机 Codex app-server 查询当前账号额度，不创建对话。登录与必要续期由 Codex 自己管理；本应用不读取登录票据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("启用 Antigravity 在线额度",isOn:Binding(get:{draft.settings.agyQuotaEnabled == true},set:{draft.settings.agyQuotaEnabled=$0}))
            if draft.settings.agyQuotaEnabled == true {
                pathField("Antigravity CLI 程序",path:Binding(get:{draft.settings.agyExecutable ?? ""},set:{draft.settings.agyExecutable=$0}),directory:false)
                Text("通过官方 /usage JSON 命令每六十秒查询；要求 CLI 1.1.11 或更新版本，不启动模型轮次。登录由原生 CLI 管理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("启用 Claude 会话额度",isOn:Binding(get:{draft.settings.claudeQuotaEnabled == true},set:{draft.settings.claudeQuotaEnabled=$0}))
            if draft.settings.claudeQuotaEnabled == true {
                pathField("Claude 额度快照",path:Binding(get:{draft.settings.claudeQuotaSnapshot ?? ""},set:{draft.settings.claudeQuotaSnapshot=$0}),directory:false)
                Text("由 Claude Code 状态栏桥接生成；约每十秒读取本地快照，不主动请求模型或额度服务。需订阅会话首次响应，超过九十秒未有新观测即过期。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if draft.settings.fleetMode != true {
                Text("单机模式只保留一台本机。若已添加其他机器，请先移除，或继续使用多机汇总。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($draft.hosts) { $host in
                hostEditor($host)
                Divider()
            }
            HStack {
                Button("添加本机") {
                    draft.hosts.append(HostDraft(name: "local-\(draft.hosts.count + 1)", executable: draft.settings.executable))
                }
                if draft.settings.fleetMode == true {
                    Button("添加 SSH 机器") { draft.hosts.append(HostDraft(name: "remote-\(draft.hosts.count + 1)", remote: true)) }
                }
            }
            DisclosureGroup("采集选项") {
                VStack(alignment: .leading) {
                    Stepper("每台机器超时：\(draft.timeout) 秒", value: $draft.timeout, in: 1...3600, step: 30)
                    Stepper("陈旧阈值：\(draft.staleAfter) 秒", value: $draft.staleAfter, in: 1...86400, step: 60)
                    Text("远程机器使用已有的 SSH 配置和来源配置；检测只读取配置指纹并运行采集，可复用原有远程缓存，不修改远程配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("检测并保存") { save() }.buttonStyle(.borderedProminent).disabled(!ready)
                if busy { ProgressView().controlSize(.small) }
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            Text("模型别名决定显示名称和目录价匹配；缺少别名的模型保留为 unknown。在线额度不在此处配置。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(busy).task { load() }
    }
    private func hostEditor(_ binding: Binding<HostDraft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("机器名称（字母、数字、._-）", text: binding.name)
                Text(binding.wrappedValue.remote ? "SSH" : "本机").font(.caption).foregroundStyle(.secondary)
                Button("移除") { let id = binding.wrappedValue.id; draft.hosts.removeAll { $0.id == id } }
            }
            if binding.wrappedValue.remote {
                TextField("SSH 主机别名或 user@host", text: binding.destination)
                TextField("远程采集器绝对路径", text: binding.executable)
                TextField("远程来源配置绝对路径", text: binding.configuration)
                TextField("远程缓存路径（可选）", text: binding.cache)
                Picker("远程命令环境", selection: binding.shell) {
                    Text("macOS / Linux").tag("posix")
                    Text("Windows PowerShell").tag("powershell")
                }
                Text("机器名称须与远程配置中的 host_id 一致；检测时自动核对配置指纹，无需手填。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                pathField("本机采集器", path: binding.executable, directory: false)
                ForEach(binding.sources) { source in sourceEditor(source, host: binding) }
                Button("添加数据来源") {
                    binding.wrappedValue.sources.append(SourceDraft(name: "source-\(binding.wrappedValue.sources.count + 1)"))
                }
                DisclosureGroup("模型别名（\(binding.wrappedValue.aliases.count)）") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(binding.aliases) { alias in
                            HStack {
                                TextField("日志中的模型名", text: alias.raw)
                                TextField("显示名称", text: alias.name)
                                Button("移除") { let id = alias.wrappedValue.id; binding.wrappedValue.aliases.removeAll { $0.id == id } }
                            }
                        }
                        Button("添加模型别名") { binding.wrappedValue.aliases.append(AliasDraft()) }
                    }
                }
            }
        }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
    private func sourceEditor(_ source: Binding<SourceDraft>, host: Binding<HostDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("来源名称（字母、数字、._-）", text: source.name)
                Button("移除来源") { let id = source.wrappedValue.id; host.wrappedValue.sources.removeAll { $0.id == id } }
            }
            Picker("Agent / 数据格式", selection: source.adapter) {
                ForEach(SourceDraft.adapters, id: \.self) { Text(adapterName($0)).tag($0) }
            }
            if source.wrappedValue.adapter == "workbuddy-jsonl" {
                Text("选择 WorkBuddy 的 projects 目录，包含主会话与子代理日志。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(source.wrappedValue.paths.indices, id: \.self) { index in
                HStack {
                    Text(source.wrappedValue.paths[index]).font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("移除路径") { source.wrappedValue.paths.remove(at: index) }
                }
            }
            HStack {
                if !["hermes-sqlite", "openclaw-sqlite"].contains(source.wrappedValue.adapter) {
                    Button("选择日志目录…") { choose(directory: true) { source.wrappedValue.paths.append($0) } }
                }
                if source.wrappedValue.adapter.hasSuffix("-sqlite") {
                    Button("选择数据库…") { choose(directory: false) { source.wrappedValue.paths.append($0) } }
                }
            }
        }.padding(8).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
    private func adapterName(_ id: String) -> String {
        ["codex-jsonl": "Codex", "claude-jsonl": "Claude Code", "workbuddy-jsonl": "WorkBuddy",
         "agy-sqlite": "Antigravity CLI", "hermes-sqlite": "Hermes", "openclaw-sqlite": "OpenClaw",
         "openclaw-codex-jsonl": "OpenClaw 专属 Codex 日志"][id] ?? id
    }
    private func pathField(_ title: String, path: Binding<String>, directory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            HStack {
                TextField(title, text: path)
                Button("选择…") { choose(directory: directory) { path.wrappedValue = $0 } }
            }
        }
    }
    private func choose(directory: Bool, selected: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { selected(url.path) }
    }
    private func newDraft() {
        do {
            original = FileManager.default.fileExists(atPath: connection.path) ? try ConfigurationEditor.read(connection) : nil
            let settings = CollectorSettings(executable: Bundle.main.url(forAuxiliaryExecutable: "agent-usage")?.path ?? "", configuration: "", stateDirectory: root.appendingPathComponent("state").path, fleetMode: true)
            draft = ConfigurationDraft(settings: settings, hosts: [HostDraft(executable: settings.executable)])
            ready = true; message = "新建草稿；检测并保存前不会改变现有连接。"
        } catch { ready = false; message = "现有连接无法安全读取，请先检查文件权限。" }
    }
    private func load() {
        if draft.settings.stateDirectory.isEmpty { draft.settings.stateDirectory = root.appendingPathComponent("state").path }
        if draft.settings.executable.isEmpty { draft.settings.executable = Bundle.main.url(forAuxiliaryExecutable: "agent-usage")?.path ?? "" }
        do {
            if FileManager.default.fileExists(atPath: connection.path) {
                let data = try ConfigurationEditor.read(connection)
                let stored = try JSONDecoder().decode(CollectorSettings.self, from: data)
                let settings = LocalCollector.reboundSettings(stored, currentExecutable: Bundle.main.url(forAuxiliaryExecutable: "agent-usage"))
                draft = try ConfigurationEditor.load(settings: settings); original = data
            } else {
                let settings = CollectorSettings(executable: Bundle.main.url(forAuxiliaryExecutable: "agent-usage")?.path ?? "", configuration: "", stateDirectory: root.appendingPathComponent("state").path, fleetMode: true)
                draft = ConfigurationDraft(settings: settings, hosts: [HostDraft(executable: settings.executable)]); original = nil
            }
            ready = true; message = ""
        } catch { ready = false; message = "配置无法读取；请检查文件或导入有效配置。现有连接未改变。" }
    }
    private func loadImport(_ path: String) {
        do {
            let expected = FileManager.default.fileExists(atPath: connection.path) ? try ConfigurationEditor.read(connection) : nil
            let imported = try ConfigurationEditor.importDraft(URL(fileURLWithPath: path), using: draft.settings)
            // A failed import must leave BOTH the previous draft and its CAS baseline intact.
            draft = imported; original = expected; ready = true
            message = "已导入草稿，检测并保存后才会切换连接。"
        } catch { message = "导入失败：配置格式不支持或本机来源配置无法读取。" }
    }
    private func save() {
        busy = true; message = "正在检测目录、配置指纹并试采集…"
        let value = draft, expected = original, connection = connection, candidates = root.appendingPathComponent("configurations")
        Task {
            do {
                let (prepared, published) = try await Task.detached {
                    let prepared = try ConfigurationEditor.prepare(value, root: candidates)
                    let published = try ConfigurationEditor.publish(prepared, connection: connection, expected: expected)
                    return (prepared, published)
                }.value
                draft.settings = prepared.settings
                guard let saved = try? ConfigurationEditor.read(connection), saved == published else {
                    ready = false; busy = false
                    message = "已保存，但当前连接已变化或无法复核；请重新载入配置。"
                    return
                }
                original = saved
                if prepared.settings.fleetMode != true || !value.hosts.contains(where: { $0.name == UserDefaults.standard.string(forKey: "agentusage.selectedHost") }) {
                    UserDefaults.standard.removeObject(forKey: "agentusage.selectedHost")
                }
                DashboardModel.invalidateScanDerivedCaches()
                FleetUIState.shared.fleet = nil; FleetUIState.shared.local = nil
                FleetUIState.shared.liveEnabled=prepared.settings.liveMetrics == true
                if prepared.settings.liveMetrics != true {FleetUIState.shared.activity=nil}
                for provider in NativeQuotaProvider.allCases {
                    let state=FleetUIState.shared.quotaState(provider)
                    state.quotaEnabled=prepared.settings.quotaEnabled(provider)
                    state.quota=nil
                }
                Task {await FleetUsageDataSource.shared.refreshAllQuotas(force:true)}
                do {
                    _ = try await FleetUsageDataSource.shared.result(force: true)
                    draft = try ConfigurationEditor.load(settings: prepared.settings)
                    message = "已保存并刷新。旧配置与连接备份已保留。"
                } catch { message = "已保存，但刷新尚未成功；请使用刷新按钮重试。旧配置与连接备份已保留。" }
            } catch ConfigurationEditError.changed {
                message = "配置已被其他操作修改，请重新载入后再保存。"
            } catch ConfigurationEditError.sourceMissing {
                message = "有来源路径不存在或不可读，请重新选择。现有连接未改变。"
            } catch ConfigurationEditError.invalid {
                message = "配置无效：请检查名称、重复来源、目录范围与采集器路径。现有连接未改变。"
            } catch {
                message = "检测或保存失败：请检查机器连接、来源格式和采集器版本。现有连接未改变。"
            }
            busy = false
        }
    }
}
