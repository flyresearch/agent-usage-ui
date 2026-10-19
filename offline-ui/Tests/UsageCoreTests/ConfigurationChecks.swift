import Foundation
import UsageCore

func configurationChecks(_ check: (String, () throws -> Void) -> Void) {
    check("coverage_fresh_does_not_mean_complete_and_empty_sources_remain_visible") {
        var value = fixture()
        value["sources"] = [["source_id": "main", "status": "ok", "files": 1, "cache_hits": 0,
                              "coverage": ["unclassified_usage_records": 2, "mirrored_usage_records": 7]],
                            ["source_id": "no-rows", "status": "unmetered", "files": 1, "cache_hits": 0,
                              "coverage": ["unmetered_files": 1]]]
        let report = CoverageReport(fleet: nil, snapshot: try decode(value))
        try require(report.available && report.current && !report.complete && report.sources.count == 2)
        try require(report.sources[0].hasGap && report.sources[0].details.first?.count == 2)
        try require(report.sources[0].details.last?.isGap == false)
        try require(report.sources[1].statusLabel == "用量未计量")
    }
    check("coverage_scope_excludes_old_configuration_and_keeps_stale_label") {
        var value = fleetFixture(); var hosts = value["hosts"] as! [[String: Any]]
        hosts[0]["state"] = "stale"; hosts[0]["error"] = "source_unreadable"; hosts[0]["failed_source_id"] = "main"
        value["hosts"] = hosts; value["complete"] = false
        let stale = CoverageReport(fleet: try decodeFleet(value), snapshot: nil)
        try require(stale.available && !stale.current && stale.sources[0].failed && stale.sources[0].retained)
        hosts[0]["state"] = "configuration_changed"; hosts[0]["included"] = false
        value["hosts"] = hosts; value["totals"] = NSNull()
        let changed = CoverageReport(fleet: try decodeFleet(value), snapshot: nil)
        try require(!changed.available && changed.sources.isEmpty && changed.unavailableHosts.count == 1)
        let absent = CoverageReport(fleet: try decodeFleet(fleetFixture()), snapshot: nil, host: "absent")
        try require(!absent.available && !absent.complete && absent.sources.isEmpty)
    }
    check("coverage_informational_counters_do_not_signal_gaps") {
        var value = fixture(); value["coverage_complete"] = true
        value["sources"] = [["source_id": "main", "status": "ok", "files": 1, "cache_hits": 1,
                              "coverage": ["mirrored_usage_records": 8, "usage_records": 9]]]
        let report = CoverageReport(fleet: nil, snapshot: try decode(value))
        try require(report.complete && !report.sources[0].hasGap)
        let failed = CoverageReport(fleet: nil, snapshot: try decode(value), refreshFailed: true)
        try require(failed.available && !failed.current && !failed.complete && failed.sources[0].retained)
        value["sources"] = [["source_id": "main", "status": "ok", "files": 1, "cache_hits": 0,
                              "coverage": ["future-diagnostic": 1]]]
        try require(!CoverageReport(fleet: nil, snapshot: try decode(value)).complete)
    }
    check("coverage_selected_host_does_not_inherit_other_hosts_gaps") {
        var value = fleetFixture()
        var hosts = value["hosts"] as! [[String: Any]]
        var other = hosts[0]; other["host_id"] = "clean-host"
        var clean = fixture(); clean["host_id"] = "clean-host"; clean["coverage_complete"] = true
        clean["sources"] = [["source_id": "main", "status": "ok", "files": 1, "cache_hits": 0, "coverage": [:]]]
        other["snapshot"] = clean; hosts.append(other); value["hosts"] = hosts
        value["totals"] = ["input": 60, "cache_read": 200, "cache_write": 0, "output": 14, "reasoning": 0]
        let fleet = try decodeFleet(value)
        let selected = CoverageReport(fleet: fleet, snapshot: nil, host: "clean-host")
        try require(selected.complete && selected.sources.count == 1 && selected.sources[0].host == "clean-host")
        try require(!CoverageReport(fleet: fleet, snapshot: nil).complete)
    }
    check("configuration_import_and_validation_preserve_sources_and_aliases") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.json")
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "host_id": "fixture",
            "sources": [["id": "main", "adapter": "workbuddy-jsonl", "paths": [root.path]]], "model_aliases": ["raw-model": "display-model"]])
        try data.write(to: config)
        let settings = CollectorSettings(executable: "/bin/echo", configuration: config.path, stateDirectory: root.appendingPathComponent("state").path)
        var draft = try ConfigurationEditor.load(settings: settings)
        try ConfigurationEditor.validate(draft)
        try require(draft.inputs[config.path] == data && draft.hosts[0].aliases[0].name == "display-model")
        draft.hosts[0].sources.append(draft.hosts[0].sources[0])
        try rejects { try ConfigurationEditor.validate(draft) }
        draft.hosts[0].sources.removeLast(); draft.hosts[0].sources[0].paths.append(root.path + "/child")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)
        try rejects { try ConfigurationEditor.validate(draft) }
        try Data("{\"schema_version\":1,\"host_id\":\"fixture\",\"sources\":[],\"new_private_option\":true}".utf8).write(to: config)
        try rejects { _ = try ConfigurationEditor.load(settings: settings) }
    }
    check("configuration_import_rejects_malformed_optional_fields_and_reads_backups") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.json"), file = root.appendingPathComponent("fleet.json")
        let local: [String: Any] = ["schema_version": 1, "host_id": "fixture", "sources": [["id": "main", "adapter": "codex-jsonl", "paths": [root.path]]]]
        try JSONSerialization.data(withJSONObject: local).write(to: source)
        let transport: [String: Any] = ["kind": "local", "executable": "/bin/echo", "config": source.path]
        var object: [String: Any] = ["schema_version": 1, "hosts": [["host_id": "fixture", "configuration_fingerprint": String(repeating: "a", count: 64), "transport": transport]]]
        let settings = CollectorSettings(executable: "/bin/echo", configuration: file.path, stateDirectory: root.appendingPathComponent("state").path, fleetMode: true)
        for invalid in ["120" as Any, true, 1.5] {
            object["timeout_seconds"] = invalid
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            try rejects { _ = try ConfigurationEditor.load(settings: settings) }
        }
        object.removeValue(forKey: "timeout_seconds")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let backup = root.appendingPathComponent("connection-backup.json")
        let bytes = try JSONEncoder().encode(settings); try bytes.write(to: backup)
        let restored = try ConfigurationEditor.importDraft(backup, using: settings)
        try require(restored.hosts.count == 1 && restored.inputs[backup.path] == bytes)
        let sourceDraft = try ConfigurationEditor.importDraft(source, using: settings)
        try require(sourceDraft.settings.fleetMode == false && sourceDraft.hosts[0].name == "fixture")
    }
    check("configuration_remote_arguments_quote_paths_and_reject_destination_options") {
        var host = HostDraft(name: "remote", remote: true, executable: "/some path/collector'file")
        host.destination = "example-host"; host.configuration = "/config/with ' quote.json"
        let args = ConfigurationEditor.remoteIdentityArguments(host)
        try require(args.contains("StrictHostKeyChecking=yes") && args.last!.contains("'\"'\"'"))
        host.shell = "powershell"
        let encoded = ConfigurationEditor.remoteIdentityArguments(host).last!.split(separator: " ").last!
        let script = String(data: Data(base64Encoded: String(encoded))!, encoding: .utf16LittleEndian)!
        try require(script.contains("collector''file") && script.contains("exit $LASTEXITCODE"))
        host.destination = "-oProxyCommand=invalid"
        let settings = CollectorSettings(executable: "/bin/echo", configuration: "", stateDirectory: "/tmp/fixture", fleetMode: true)
        try rejects { try ConfigurationEditor.validate(ConfigurationDraft(settings: settings, hosts: [host])) }
    }
    if let binary = ProcessInfo.processInfo.environment["AGENT_USAGE_TEST_COLLECTOR"] {
        check("configuration_actual_collector_prepare_publish_and_conflict") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let logs = root.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":10,\"output_tokens\":2}}}}\n".utf8).write(to: logs.appendingPathComponent("a.jsonl"))
            let settings = CollectorSettings(executable: binary, configuration: "", stateDirectory: root.appendingPathComponent("live-state").path, fleetMode: true)
            var host = HostDraft(name: "fixture", executable: binary); host.sources = [SourceDraft(name: "source", paths: [logs.path])]
            let draft = ConfigurationDraft(settings: settings, hosts: [host])
            let prepared = try ConfigurationEditor.prepare(draft, root: root.appendingPathComponent("candidates"))
            guard case .fleet(let fleet) = prepared.result else { throw CheckFailure.failed }
            try require(fleet.complete && fleet.totals?.total == 12)
            try require(!FileManager.default.fileExists(atPath: settings.stateDirectory))
            let connection = root.appendingPathComponent("connection.json")
            // A candidate changed AFTER successful collection cannot be published.
            let candidate = URL(fileURLWithPath: prepared.settings.configuration)
            let candidateBytes = try ConfigurationEditor.read(candidate)
            try Data("changed".utf8).write(to: candidate)
            try rejects { try ConfigurationEditor.publish(prepared, connection: connection, expected: nil) }
            try require(!FileManager.default.fileExists(atPath: connection.path))
            try candidateBytes.write(to: candidate)
            let published = try ConfigurationEditor.publish(prepared, connection: connection, expected: nil)
            try require(published == ConfigurationEditor.read(connection))
            let saved = try ConfigurationEditor.read(connection)
            let restored = try ConfigurationEditor.load(settings: JSONDecoder().decode(CollectorSettings.self, from: saved))
            try require(restored.hosts[0].sources[0].paths == [logs.path])
            try rejects { try ConfigurationEditor.publish(prepared, connection: connection, expected: nil) }
            try require(ConfigurationEditor.read(connection) == saved)
            // A change to an imported source config fences both prepare and publication.
            let sourceConfig = Array(restored.inputs.keys).first(where: { $0.hasSuffix("config.json") })!
            let old = try ConfigurationEditor.read(URL(fileURLWithPath: sourceConfig))
            try Data("changed".utf8).write(to: URL(fileURLWithPath: sourceConfig))
            try rejects { _ = try ConfigurationEditor.prepare(restored, root: root.appendingPathComponent("candidates")) }
            try old.write(to: URL(fileURLWithPath: sourceConfig))
            let next = try ConfigurationEditor.prepare(restored, root: root.appendingPathComponent("candidates"))
            try Data("changed".utf8).write(to: URL(fileURLWithPath: sourceConfig))
            try rejects { try ConfigurationEditor.publish(next, connection: connection, expected: saved) }
            try require(ConfigurationEditor.read(connection) == saved)
            try old.write(to: URL(fileURLWithPath: sourceConfig))
            try ConfigurationEditor.publish(next, connection: connection, expected: saved)
            let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("connection-backup-") }
            try require(backups.count == 1 && ConfigurationEditor.read(backups[0]) == saved)
            let attributes = try FileManager.default.attributesOfItem(atPath: connection.path)
            try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            var single = draft; single.settings.fleetMode = false
            let local = try ConfigurationEditor.prepare(single, root: root.appendingPathComponent("candidates"))
            guard case .local(let snapshot) = local.result else { throw CheckFailure.failed }
            try require(snapshot.totals.total == 12)
            try require(ConfigurationEditor.load(settings: local.settings).hosts.count == 1)
        }
        check("configuration_failed_trial_keeps_live_connection_and_removes_candidate") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let logs = root.appendingPathComponent("logs"), candidates = root.appendingPathComponent("candidates")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("invalid JSON\n".utf8).write(to: logs.appendingPathComponent("a.jsonl"))
            let settings = CollectorSettings(executable: binary, configuration: "", stateDirectory: root.appendingPathComponent("live-state").path, fleetMode: true)
            var host = HostDraft(name: "fixture", executable: binary); host.sources = [SourceDraft(name: "source", paths: [logs.path])]
            try rejects { _ = try ConfigurationEditor.prepare(ConfigurationDraft(settings: settings, hosts: [host]), root: candidates) }
            try require(FileManager.default.contentsOfDirectory(atPath: candidates.path).isEmpty)
            try require(!FileManager.default.fileExists(atPath: settings.stateDirectory))
        }
    }
}
