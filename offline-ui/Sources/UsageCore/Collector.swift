import Foundation
import Darwin

public struct CollectorSettings: Codable, Sendable {
    public var executable: String
    public var configuration: String
    public var stateDirectory: String
    public var fleetMode: Bool?
    public var autoRefresh: Bool?
    public var liveMetrics: Bool?
    public var refreshIntervalSeconds: Int?
    public static let refreshIntervals=[60,300,900,1800,3600]
    public func collectionInterval() throws -> TimeInterval {
        let seconds=refreshIntervalSeconds ?? 300
        guard Self.refreshIntervals.contains(seconds) else {throw UsageError.configurationChanged}
        return liveMetrics == true ? 30:TimeInterval(seconds)
    }
    public var codexQuotaEnabled: Bool?
    public var codexExecutable: String?
    public var agyQuotaEnabled: Bool?
    public var agyExecutable: String?
    public var claudeQuotaEnabled: Bool?
    public var claudeQuotaSnapshot: String?
    public func quotaEnabled(_ provider:NativeQuotaProvider) -> Bool {provider == .codex ? codexQuotaEnabled == true:provider == .agy ? agyQuotaEnabled == true:claudeQuotaEnabled == true}
    public func quotaExecutable(_ provider:NativeQuotaProvider) -> String {provider == .codex ? codexExecutable ?? "":provider == .agy ? agyExecutable ?? "":claudeQuotaSnapshot ?? ""}
    public init(executable: String, configuration: String, stateDirectory: String, fleetMode: Bool? = nil) {self.executable=executable;self.configuration=configuration;self.stateDirectory=stateDirectory;self.fleetMode=fleetMode}
}
public enum CollectionResult: Sendable {
    case local(UsageSnapshot)
    case fleet(FleetSnapshot)
}
public enum LocalCollector {
    /// Upgrade an app-owned bundled collector without overriding a custom CLI.
    /// The executable path alone is insufficient: require the owned bundle ID.
    public static func reboundSettings(_ settings:CollectorSettings,currentExecutable:URL?) -> CollectorSettings {
        guard let currentExecutable,FileManager.default.isExecutableFile(atPath:currentExecutable.path) else {return settings}
        let old=URL(fileURLWithPath:settings.executable)
        guard old.lastPathComponent=="agent-usage",old.deletingLastPathComponent().lastPathComponent=="MacOS",old.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent=="Contents" else {return settings}
        let bundle=old.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension=="app",let data=try? Data(contentsOf:bundle.appendingPathComponent("Contents/Info.plist")),let plist=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any],plist["CFBundleIdentifier"] as? String=="org.flyresearch.agentusage" else {return settings}
        var value=settings;value.executable=currentExecutable.path;return value
    }
    public static func refresh(_ settings: CollectorSettings, timeout: TimeInterval = 120) throws -> UsageSnapshot {
        try withLocalLock(settings) {
            let state=URL(fileURLWithPath:settings.stateDirectory,isDirectory:true)
            let data=try execute(settings,arguments:["collect","--config",settings.configuration,"--cache",state.appendingPathComponent("cache.json").path],timeout:timeout)
            let snapshot=try UsageSnapshot.decode(data)
            try checkConfiguration(settings,snapshot:snapshot)
            try publish(data,to:state.appendingPathComponent("snapshot.json"))
            return snapshot
        }
    }
    public static func refreshResult(_ settings:CollectorSettings, expectedLocalFingerprint:String? = nil) throws -> CollectionResult {
        if settings.fleetMode == true {return .fleet(try fleet(settings,refresh:true))}
        do {return .local(try refresh(settings))}
        catch {
            if let expectedLocalFingerprint, (try? configurationIdentity(settings).configuration_fingerprint) != expectedLocalFingerprint {throw UsageError.configurationChanged}
            throw error
        }
    }
    public static func restoreResult(_ settings:CollectorSettings) throws -> CollectionResult {
        if settings.fleetMode == true {return .fleet(try fleet(settings,refresh:false))}
        return .local(try saved(settings))
    }
    public static func fleet(_ settings:CollectorSettings,refresh:Bool) throws -> FleetSnapshot {
        if refresh {try FileManager.default.createDirectory(atPath:settings.stateDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        let path=URL(fileURLWithPath:settings.stateDirectory).appendingPathComponent("fleet.db").path
        let data=try execute(settings,arguments:[refresh ? "fleet-sync" : "fleet-report","--config",settings.configuration,"--store",path],timeout:refresh ? 600 : 15)
        return try FleetSnapshot.decode(data)
    }
    private struct ConfigurationIdentity:Decodable {
        let schema_version:Int
        let kind:String
        let host_id:String
        let configuration_fingerprint:String
    }
    private static func configurationIdentity(_ settings:CollectorSettings) throws -> ConfigurationIdentity {
        do {
            let data=try execute(settings,arguments:["config-id","--config",settings.configuration],timeout:15)
            let identity=try JSONDecoder().decode(ConfigurationIdentity.self,from:data)
            guard identity.schema_version==1,identity.kind=="configuration_identity",label(identity.host_id),fingerprint(identity.configuration_fingerprint) else {throw UsageError.configurationChanged}
            return identity
        } catch {throw UsageError.configurationChanged}
    }
    private static func checkConfiguration(_ settings:CollectorSettings,snapshot:UsageSnapshot) throws {
        let current=try configurationIdentity(settings)
        guard current.host_id==snapshot.host_id,current.configuration_fingerprint==snapshot.configuration_fingerprint else {throw UsageError.configurationChanged}
    }
    public static func saved(_ settings: CollectorSettings) throws -> UsageSnapshot {
        let url=URL(fileURLWithPath:settings.stateDirectory).appendingPathComponent("snapshot.json")
        let fd=Darwin.open(url.path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW);guard fd>=0 else {throw UsageError.collectionFailed}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer {try? handle.close()}
        var info=stat();guard fstat(handle.fileDescriptor,&info)==0,(info.st_mode & S_IFMT)==S_IFREG else {throw UsageError.invalidSnapshot}
        var data=Data()
        while let chunk=try handle.read(upToCount:65536),!chunk.isEmpty {
            guard data.count+chunk.count<=64*1024*1024 else {throw UsageError.outputTooLarge};data.append(chunk)
        }
        let snapshot=try UsageSnapshot.decode(data);try checkConfiguration(settings,snapshot:snapshot);return snapshot
    }
    private static func withLocalLock<T>(_ settings:CollectorSettings,_ body:() throws ->T) throws ->T {
        try FileManager.default.createDirectory(atPath:settings.stateDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let path=URL(fileURLWithPath:settings.stateDirectory).appendingPathComponent(".ui-local-refresh.lock").path
        let fd=Darwin.open(path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600);guard fd>=0 else {throw UsageError.collectionFailed};defer {Darwin.close(fd)}
        var info=stat();guard fstat(fd,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_size==0,info.st_nlink==1,flock(fd,LOCK_EX|LOCK_NB)==0 else {throw UsageError.collectionFailed}
        defer {flock(fd,LOCK_UN)}
        return try body()
    }
    static func publish(_ data:Data,to destination:URL) throws {
        let temp=destination.deletingLastPathComponent().appendingPathComponent("snapshot-"+UUID().uuidString+".tmp")
        let fd=Darwin.open(temp.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600);guard fd>=0 else {throw UsageError.collectionFailed}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer {try? file.close();try? FileManager.default.removeItem(at:temp)}
        try file.write(contentsOf:data);try file.synchronize();try file.close()
        guard Darwin.rename(temp.path,destination.path)==0 else {throw UsageError.collectionFailed}
    }
    // Nonblocking reads keep deadline enforcement independent of EOF, including
    // a descendant that inherits stdout after the direct child exits.
    public static func execute(_ settings:CollectorSettings,arguments:[String],timeout:TimeInterval,workingDirectory:String?=nil,inheritSSHAgent:Bool=true,outputLimit:Int=64*1024*1024) throws -> Data {
        let process=Process();process.executableURL=URL(fileURLWithPath:settings.executable);process.arguments=arguments
        var environment=["HOME":NSHomeDirectory(),"TMPDIR":NSTemporaryDirectory(),"PATH":"/usr/bin:/bin"]
        if inheritSSHAgent,let socket=ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {environment["SSH_AUTH_SOCK"]=socket}
        if let workingDirectory {process.currentDirectoryURL=URL(fileURLWithPath:workingDirectory)}
        process.environment=environment;process.standardInput=FileHandle.nullDevice
        let pipe=Pipe();process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
        let handle=pipe.fileHandleForReading;let fd=handle.fileDescriptor
        guard fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK) != -1 else {throw UsageError.collectionFailed}
        do {try process.run()} catch {throw UsageError.collectionFailed}
        defer {
            if process.isRunning {kill(process.processIdentifier,SIGKILL)}
            process.waitUntilExit();try? handle.close()
        }
        let start=ProcessInfo.processInfo.systemUptime
        var data=Data();var buffer=[UInt8](repeating:0,count:65536);var eof=false
        while true {
            if ProcessInfo.processInfo.systemUptime-start>=max(timeout,0.05) {throw UsageError.timedOut}
            let n=Darwin.read(fd,&buffer,buffer.count)
            if n>0 {
                guard data.count+n<=outputLimit else {throw UsageError.outputTooLarge}
                data.append(contentsOf:buffer.prefix(n))
            } else if n==0 {eof=true}
            else if errno != EAGAIN && errno != EINTR {throw UsageError.collectionFailed}
            if eof && !process.isRunning {break}
            if n<=0 {Thread.sleep(forTimeInterval:0.01)}
        }
        guard process.terminationStatus==0 else {
            if let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let code=object["error"] as? String,
               ["configuration_changed","fleet_configuration_changed","invalid_fleet_config","fleet_config_read_failed"].contains(code) {throw UsageError.configurationChanged}
            if let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let source=object["source_id"] as? String,label(source) {throw UsageError.sourceFailure(source)}
            throw UsageError.collectionFailed
        }
        return data
    }
}
