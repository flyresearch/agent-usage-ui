import Foundation
import Darwin
import CoreFoundation

public enum ConfigurationEditError: Error { case invalid, changed, busy, validationFailed, sourceMissing }
public struct SourceDraft: Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var adapter: String
    public var paths: [String]
    public init(name: String = "source", adapter: String = "codex-jsonl", paths: [String] = []) {
        self.name = name; self.adapter = adapter; self.paths = paths
    }
    public static let adapters = ["codex-jsonl", "claude-jsonl", "workbuddy-jsonl", "agy-sqlite", "hermes-sqlite", "openclaw-sqlite", "openclaw-codex-jsonl"]
}
public struct AliasDraft: Identifiable, Sendable {
    public var id = UUID()
    public var raw: String
    public var name: String
    public init(raw: String = "", name: String = "") { self.raw = raw; self.name = name }
}
public struct HostDraft: Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var remote: Bool
    public var destination: String
    public var executable: String
    public var configuration: String
    public var shell: String
    public var cache: String
    public var sources: [SourceDraft]
    public var aliases: [AliasDraft]
    public init(name: String = "local", remote: Bool = false, executable: String = "") {
        self.name = name; self.remote = remote; self.executable = executable
        destination = ""; configuration = ""; shell = "posix"; cache = ""; sources = []; aliases = []
    }
}
public struct ConfigurationDraft: Sendable {
    public var settings: CollectorSettings
    public var hosts: [HostDraft]
    public var timeout: Int = 120
    public var staleAfter: Int = 900
    public var inputs: [String: Data] = [:]
    public init(settings: CollectorSettings, hosts: [HostDraft] = []) { self.settings = settings; self.hosts = hosts }
}
public struct PreparedConfiguration: Sendable {
    public let settings: CollectorSettings
    public let result: CollectionResult
    public let directory: URL
    public let inputs: [String: Data]
}

/// Immutable candidate directories keep the previous source/fleet configurations
/// untouched. The only publication point is the app-owned connection.json.
public enum ConfigurationEditor {
    private static let maxConfigBytes = 4 * 1024 * 1024
    public static func read(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw ConfigurationEditError.invalid }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxConfigBytes else { throw ConfigurationEditError.invalid }
        let data = try file.read(upToCount: maxConfigBytes + 1) ?? Data()
        guard data.count <= maxConfigBytes else { throw ConfigurationEditError.invalid }
        return data
    }
    private static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(o.keys).isSubset(of: keys) else { throw ConfigurationEditError.invalid }
        return o
    }
    private static func integer(_ object: [String: Any], _ key: String, default fallback: Int? = nil) throws -> Int {
        guard let value = object[key] else {
            if let fallback { return fallback }
            throw ConfigurationEditError.invalid
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let result = value as? Int else { throw ConfigurationEditError.invalid }
        return result
    }
    private static func text(_ object: [String: Any], _ key: String, default fallback: String? = nil, nullable: Bool = false) throws -> String {
        guard let value = object[key] else {
            if let fallback { return fallback }
            throw ConfigurationEditError.invalid
        }
        if nullable && value is NSNull { return fallback ?? "" }
        guard let result = value as? String else { throw ConfigurationEditError.invalid }
        return result
    }
    /// Import accepts source/fleet configurations or a previous connection backup.
    /// The caller publishes the returned draft only after the entire import succeeds.
    public static func importDraft(_ url: URL, using current: CollectorSettings) throws -> ConfigurationDraft {
        let data = try read(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigurationEditError.invalid }
        var settings = current
        if object["executable"] != nil || object["stateDirectory"] != nil {
            guard Set(object.keys).isSubset(of: ["executable", "configuration", "stateDirectory", "fleetMode", "autoRefresh"]) else { throw ConfigurationEditError.invalid }
            settings = try JSONDecoder().decode(CollectorSettings.self, from: data)
        } else {
            settings.configuration = url.path
            settings.fleetMode = object["hosts"] != nil
        }
        var draft = try load(settings: settings)
        draft.inputs[url.path] = data
        return draft
    }
    private static func local(_ data: Data, into host: inout HostDraft) throws {
        let o = try object(data, keys: ["schema_version", "host_id", "sources", "model_aliases"])
        guard try integer(o, "schema_version") == 1, let name = o["host_id"] as? String,
              let sources = o["sources"] as? [[String: Any]] else { throw ConfigurationEditError.invalid }
        guard host.name == name else { throw ConfigurationEditError.invalid }
        host.sources = try sources.map { s in
            guard Set(s.keys).isSubset(of: ["id", "adapter", "paths"]), let id = s["id"] as? String,
                  let adapter = s["adapter"] as? String, let paths = s["paths"] as? [String] else { throw ConfigurationEditError.invalid }
            return SourceDraft(name: id, adapter: adapter, paths: paths)
        }
        let aliases: [String: String]
        if let value = o["model_aliases"] { guard let map = value as? [String: String] else { throw ConfigurationEditError.invalid }; aliases = map }
        else { aliases = [:] }
        host.aliases = aliases.sorted { $0.key < $1.key }.map { AliasDraft(raw: $0.key, name: $0.value) }
    }
    public static func load(settings: CollectorSettings) throws -> ConfigurationDraft {
        var draft = ConfigurationDraft(settings: settings)
        let input = try read(URL(fileURLWithPath: settings.configuration))
        draft.inputs[settings.configuration] = input
        if settings.fleetMode == true {
            let o = try object(input, keys: ["schema_version", "hosts", "timeout_seconds", "stale_after_seconds"])
            guard try integer(o, "schema_version") == 1, let hosts = o["hosts"] as? [[String: Any]] else { throw ConfigurationEditError.invalid }
            draft.timeout = try integer(o, "timeout_seconds", default: 120)
            draft.staleAfter = try integer(o, "stale_after_seconds", default: 900)
            for h in hosts {
                guard Set(h.keys).isSubset(of: ["host_id", "configuration_fingerprint", "transport"]), let name = h["host_id"] as? String,
                      let t = h["transport"] as? [String: Any], Set(t.keys).isSubset(of: ["kind", "destination", "executable", "config", "cache", "shell"]),
                      let kind = t["kind"] as? String, ["local", "ssh"].contains(kind),
                      let exe = t["executable"] as? String, let config = t["config"] as? String else { throw ConfigurationEditError.invalid }
                var host = HostDraft(name: name, remote: kind == "ssh", executable: exe)
                host.configuration = config
                host.destination = try text(t, "destination", default: "")
                host.shell = try text(t, "shell", default: "posix")
                host.cache = try text(t, "cache", default: "", nullable: true)
                if !host.remote {
                    let data = try read(URL(fileURLWithPath: config))
                    draft.inputs[config] = data
                    try local(data, into: &host)
                }
                draft.hosts.append(host)
            }
        } else {
            let o = try object(input, keys: ["schema_version", "host_id", "sources", "model_aliases"])
            guard let name = o["host_id"] as? String else { throw ConfigurationEditError.invalid }
            var host = HostDraft(name: name, executable: settings.executable)
            try local(input, into: &host); draft.hosts = [host]
        }
        return draft
    }
    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func unchanged(_ inputs: [String: Data]) throws {
        for (path, data) in inputs { guard try read(URL(fileURLWithPath: path)) == data else { throw ConfigurationEditError.changed } }
    }
    public static func validate(_ draft: ConfigurationDraft) throws {
        guard draft.settings.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: draft.settings.executable),
              draft.settings.stateDirectory.hasPrefix("/"), !draft.hosts.isEmpty, draft.hosts.count <= 64,
              Set(draft.hosts.map(\.name)).count == draft.hosts.count,
              (1...3600).contains(draft.timeout), (1...86400).contains(draft.staleAfter) else { throw ConfigurationEditError.invalid }
        if draft.settings.fleetMode != true && (draft.hosts.count != 1 || draft.hosts[0].remote) { throw ConfigurationEditError.invalid }
        for host in draft.hosts {
            guard label(host.name), validPath(host.executable) else { throw ConfigurationEditError.invalid }
            if host.remote {
                guard !host.destination.isEmpty, host.destination.utf8.count <= 255, !host.destination.hasPrefix("-"),
                      host.destination.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [46,95,45,64,58].contains($0) }),
                      ["posix", "powershell"].contains(host.shell), validPath(host.configuration) else { throw ConfigurationEditError.invalid }
            } else {
                guard host.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: host.executable),
                      !host.sources.isEmpty, Set(host.sources.map(\.name)).count == host.sources.count,
                      Set(host.aliases.map(\.raw)).count == host.aliases.count,
                      host.aliases.allSatisfy({ !$0.raw.isEmpty && label($0.name) }) else { throw ConfigurationEditError.invalid }
                var roots = [String]()
                for source in host.sources {
                    guard label(source.name), SourceDraft.adapters.contains(source.adapter), !source.paths.isEmpty else { throw ConfigurationEditError.invalid }
                    for path in source.paths {
                        guard path.hasPrefix("/"), validPath(path) else { throw ConfigurationEditError.invalid }
                        var directory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), FileManager.default.isReadableFile(atPath: path) else { throw ConfigurationEditError.sourceMissing }
                        let database = ["hermes-sqlite", "openclaw-sqlite"].contains(source.adapter)
                        guard database ? !directory.boolValue : source.adapter == "agy-sqlite" || directory.boolValue else { throw ConfigurationEditError.invalid }
                        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
                        guard !roots.contains(where: { $0 == root || $0.hasPrefix(root + "/") || root.hasPrefix($0 + "/") }) else { throw ConfigurationEditError.invalid }
                        roots.append(root)
                    }
                }
            }
        }
    }
    private static func write(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConfigurationEditError.invalid }
        let f = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? f.close() }
        try f.write(contentsOf: data); try f.synchronize()
    }
    private static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) }
    private static func identity(_ data: Data, host: String) throws -> String {
        let o = try object(data, keys: ["schema_version", "kind", "host_id", "configuration_fingerprint"])
        guard try integer(o, "schema_version") == 1, o["kind"] as? String == "configuration_identity", o["host_id"] as? String == host,
              let f = o["configuration_fingerprint"] as? String, fingerprint(f) else { throw ConfigurationEditError.validationFailed }
        return f
    }
    public static func remoteIdentityArguments(_ host: HostDraft) -> [String] {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: host.shell == "powershell" ? "''" : "'\"'\"'") + "'" }
        let words = [host.executable, "config-id", "--config", host.configuration].map(quote).joined(separator: " ")
        let command: String
        if host.shell == "powershell" {
            let script = "& " + words + "; exit $LASTEXITCODE"
            command = "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + Data(script.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }).base64EncodedString()
        } else { command = words }
        return ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", host.destination, command]
    }
    public static func prepare(_ draft: ConfigurationDraft, root: URL) throws -> PreparedConfiguration {
        try validate(draft)
        try unchanged(draft.inputs)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var success = false
        defer { if !success { try? fm.removeItem(at: directory) } }
        var hosts = [[String: Any]]()
        var sealed = draft.inputs
        var onlyLocalPath = ""
        for (index, host) in draft.hosts.enumerated() {
            var settings = draft.settings
            settings.executable = host.executable
            var config = host.configuration
            let hash: String
            if host.remote {
                settings.executable = "/usr/bin/ssh"
                hash = try identity(LocalCollector.execute(settings, arguments: remoteIdentityArguments(host), timeout: 30), host: host.name)
            } else {
                let hostRoot = directory.appendingPathComponent("host-\(index)", isDirectory: true)
                try fm.createDirectory(at: hostRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                config = hostRoot.appendingPathComponent("config.json").path
                let aliases = Dictionary(uniqueKeysWithValues: host.aliases.map { ($0.raw, $0.name) })
                try write(json(["schema_version": 1, "host_id": host.name, "model_aliases": aliases,
                                "sources": host.sources.map { ["id": $0.name, "adapter": $0.adapter, "paths": $0.paths] as [String: Any] }]), to: URL(fileURLWithPath: config))
                sealed[config] = try read(URL(fileURLWithPath: config))
                hash = try identity(LocalCollector.execute(settings, arguments: ["config-id", "--config", config], timeout: 15), host: host.name)
                onlyLocalPath = config
            }
            var transport: [String: Any] = ["kind": host.remote ? "ssh" : "local", "executable": host.executable, "config": config]
            if host.remote {
                transport["destination"] = host.destination; transport["shell"] = host.shell
                if !host.cache.isEmpty {
                    guard validPath(host.cache) else { throw ConfigurationEditError.invalid }
                    transport["cache"] = host.cache
                }
            } else { transport["cache"] = URL(fileURLWithPath: config).deletingLastPathComponent().appendingPathComponent("cache.json").path }
            hosts.append(["host_id": host.name, "configuration_fingerprint": hash, "transport": transport])
        }
        var prepared = draft.settings
        if prepared.fleetMode == true {
            let file = directory.appendingPathComponent("fleet.json")
            try write(json(["schema_version": 1, "timeout_seconds": draft.timeout, "stale_after_seconds": draft.staleAfter, "hosts": hosts]), to: file)
            sealed[file.path] = try read(file)
            prepared.configuration = file.path
        } else { prepared.configuration = onlyLocalPath; prepared.executable = draft.hosts[0].executable }
        // The test store/cache are separate from every config directory and from
        // the live store. Remote collectors may reuse their configured cache.
        var test = prepared
        test.stateDirectory = directory.appendingPathComponent("test-state").path
        let result = try LocalCollector.refreshResult(test)
        if case .fleet(let fleet) = result, !fleet.complete { throw ConfigurationEditError.validationFailed }
        try unchanged(sealed)
        success = true
        return PreparedConfiguration(settings: prepared, result: result, directory: directory, inputs: sealed)
    }
    @discardableResult
    public static func publish(_ prepared: PreparedConfiguration, connection: URL, expected: Data?) throws -> Data {
        let parent = connection.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(parent.appendingPathComponent(".configuration-editor.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConfigurationEditError.busy }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == 0, info.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConfigurationEditError.busy }
        defer { flock(fd, LOCK_UN) }
        try unchanged(prepared.inputs)
        if let expected { guard try read(connection) == expected else { throw ConfigurationEditError.changed } }
        else { guard !FileManager.default.fileExists(atPath: connection.path) else { throw ConfigurationEditError.changed } }
        // Persist a rollback connection before the single atomic pointer switch.
        if let expected { try write(expected, to: parent.appendingPathComponent("connection-backup-" + UUID().uuidString + ".json")) }
        let temp = parent.appendingPathComponent("connection-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        let published = try JSONEncoder().encode(prepared.settings)
        try write(published, to: temp)
        guard Darwin.rename(temp.path, connection.path) == 0 else { throw ConfigurationEditError.invalid }
        return published
    }
}
