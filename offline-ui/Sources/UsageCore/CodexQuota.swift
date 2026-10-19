import Foundation
import CryptoKit
import Darwin
import CoreFoundation

public enum NativeQuotaError: Error, Sendable { case missingSample, staleSample, notLoggedIn, unsupportedAccount, unsupportedVersion, invalidResponse, requestFailed, timedOut, launchFailed, cancelled }
public struct NativeQuotaWindow: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public var remainingPercent: Double { max(0,100-usedPercent) }
}
public struct NativeQuotaSnapshot: Sendable {
    public let capturedAt: Date
    public let windows: [NativeQuotaWindow]
    public let coverageComplete: Bool
    public var continuityKey: String? = nil
    public init(capturedAt:Date,windows:[NativeQuotaWindow],coverageComplete:Bool=true) {
        self.capturedAt=capturedAt;self.windows=windows;self.coverageComplete=coverageComplete
    }
    public func fresh(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(capturedAt) >= -5 && now.timeIntervalSince(capturedAt) <= 90
    }
    public func remaining(at now: Date = Date()) -> Double? {
        guard fresh(at:now), coverageComplete, !windows.isEmpty,
              windows.allSatisfy({ $0.resetsAt == nil || $0.resetsAt! > now }) else {return nil}
        return windows.map(\.remainingPercent).min()
    }
}

/// A separate opt-in bridge to the official local Codex app-server. It never
/// reads auth files, starts a thread/turn, logs RPC bodies or persists account data.
public enum CodexQuota {
    private static func number(_ value: Any?) -> Double? {
        guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {return nil}
        return n.doubleValue
    }
    public static func decodeLimits(_ result: Data, now: Date = Date()) throws -> NativeQuotaSnapshot {
        guard let object=(try? JSONSerialization.jsonObject(with:result)) as? [String:Any] else {throw NativeQuotaError.invalidResponse}
        let groups: [[String:Any]]
        let groupKeys:[String]
        if let value=object["rateLimitsByLimitId"], !(value is NSNull) {
            guard let map=value as? [String:Any] else {throw NativeQuotaError.invalidResponse}
            groupKeys=map.keys.sorted()
            groups=try groupKeys.map { key in
                guard let value=map[key] as? [String:Any] else {throw NativeQuotaError.invalidResponse};return value
            }
        } else if let value=object["rateLimits"] as? [String:Any] { groups=[value];groupKeys=["legacy"] }
        else {throw NativeQuotaError.invalidResponse}
        guard groups.count<=64 else {throw NativeQuotaError.invalidResponse}
        var windows=[NativeQuotaWindow]()
        for (index,group) in groups.enumerated() {
            for kind in ["primary","secondary"] {
                guard let value=group[kind], !(value is NSNull) else {continue}
                guard let window=value as? [String:Any],let used=number(window["usedPercent"]),(0...100).contains(used) else {throw NativeQuotaError.invalidResponse}
                var duration:Int?
                if let value=window["windowDurationMins"], !(value is NSNull) {
                    guard let d=number(value),d.rounded()==d,d>0,d<=525600 else {throw NativeQuotaError.invalidResponse};duration=Int(d)
                }
                var reset:Date?
                if let value=window["resetsAt"], !(value is NSNull) {
                    guard let t=number(value),t.rounded()==t,t>0,t<253402300800 else {throw NativeQuotaError.invalidResponse};reset=Date(timeIntervalSince1970:t)
                }
                // Do not expose provider-supplied names or account identifiers.
                let title=(groups.count>1 ? "额度分组 \(index+1) · " : "")+(kind == "primary" ? "主要窗口" : "次要窗口")
                windows.append(NativeQuotaWindow(id:"bucket-"+SHA256.hash(data:Data(groupKeys[index].utf8)).map{String(format:"%02x",$0)}.joined()+"-"+kind,title:title,usedPercent:used,durationMinutes:duration,resetsAt:reset))
            }
        }
        guard !windows.isEmpty else {throw NativeQuotaError.unsupportedAccount}
        return NativeQuotaSnapshot(capturedAt:now,windows:windows)
    }
    public static func fetch(executable: String, timeout: TimeInterval = 20) throws -> NativeQuotaSnapshot {
        guard executable.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:executable) else {throw NativeQuotaError.launchFailed}
        let process=Process();process.executableURL=URL(fileURLWithPath:executable)
        process.arguments=["app-server","--listen","stdio://","-c","mcp_servers={}","-c","analytics.enabled=false","--disable","apps","--disable","plugins","--disable","remote_plugin"]
        process.environment=["HOME":NSHomeDirectory(),"TMPDIR":NSTemporaryDirectory(),"PATH":URL(fileURLWithPath:executable).deletingLastPathComponent().path+":/usr/bin:/bin"]
        process.currentDirectoryURL=FileManager.default.temporaryDirectory
        let input=Pipe(),output=Pipe();process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        let reader=output.fileHandleForReading,writer=input.fileHandleForWriting
        guard fcntl(writer.fileDescriptor,F_SETNOSIGPIPE,1) != -1 else {throw NativeQuotaError.launchFailed}
        let fd=reader.fileDescriptor
        guard fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK) != -1 else {throw NativeQuotaError.launchFailed}
        do {try process.run()} catch {throw NativeQuotaError.launchFailed}
        defer {
            try? writer.close()
            // Normal stdin EOF lets the native CLI finish its own state writes.
            // Timeout/cancellation still has a bounded teardown and exact child PID.
            let grace=ProcessInfo.processInfo.systemUptime+0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime<grace {Thread.sleep(forTimeInterval:0.01)}
            if process.isRunning {kill(process.processIdentifier,SIGTERM)}
            let termination=ProcessInfo.processInfo.systemUptime+0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime<termination {Thread.sleep(forTimeInterval:0.01)}
            if process.isRunning {kill(process.processIdentifier,SIGKILL)}
            process.waitUntilExit();try? reader.close()
        }
        var pending=Data();var received=0;let started=ProcessInfo.processInfo.systemUptime
        func send(_ value:[String:Any]) throws {
            let bytes=try JSONSerialization.data(withJSONObject:value)+Data([10])
            do {try writer.write(contentsOf:bytes)} catch {throw NativeQuotaError.requestFailed}
        }
        func response(_ id:Int) throws -> [String:Any] {
            var buffer=[UInt8](repeating:0,count:16384)
            while true {
                if Task.isCancelled {throw NativeQuotaError.cancelled}
                guard ProcessInfo.processInfo.systemUptime-started<max(timeout,0.05) else {throw NativeQuotaError.timedOut}
                while let newline=pending.firstIndex(of:10) {
                    let line=pending.prefix(upTo:newline);pending.removeSubrange(...newline)
                    if line.allSatisfy({[9,13,32].contains($0)}) {continue}
                    guard let message=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any] else {throw NativeQuotaError.invalidResponse}
                    if message["method"] != nil {
                        // No caller-owned auth refresh, approval or tool execution is supported.
                        if message["id"] != nil {throw NativeQuotaError.requestFailed}
                        continue
                    }
                    guard let actual=number(message["id"]),actual==Double(id) else {continue}
                    guard message["error"] == nil,let result=message["result"] as? [String:Any] else {throw NativeQuotaError.requestFailed}
                    return result
                }
                let n=Darwin.read(fd,&buffer,buffer.count)
                if n>0 {
                    received+=n;guard received<=2*1024*1024 else {throw NativeQuotaError.invalidResponse}
                    pending.append(contentsOf:buffer.prefix(n))
                } else if n==0 {throw NativeQuotaError.requestFailed}
                else if errno != EAGAIN && errno != EINTR {throw NativeQuotaError.requestFailed}
                if n<=0 {Thread.sleep(forTimeInterval:0.01)}
            }
        }
        try send(["id":1,"method":"initialize","params":["clientInfo":["name":"agent_usage_quota","title":"Agent Usage","version":"0.1.0"],"capabilities":["experimentalApi":false]]])
        _=try response(1)
        try send(["method":"initialized"])
        try send(["id":2,"method":"account/read","params":["refreshToken":false]])
        let before=try response(2)
        guard let account=before["account"] as? [String:Any] else {throw NativeQuotaError.notLoggedIn}
        guard account["type"] as? String == "chatgpt" else {throw NativeQuotaError.unsupportedAccount}
        let binding=try JSONSerialization.data(withJSONObject:account,options:.sortedKeys)
        try send(["id":3,"method":"account/rateLimits/read"])
        let limits=try response(3)
        try send(["id":4,"method":"account/read","params":["refreshToken":false]])
        let after=try response(4)
        guard let current=after["account"] as? [String:Any],try JSONSerialization.data(withJSONObject:current,options:.sortedKeys)==binding else {throw NativeQuotaError.requestFailed}
        var snapshot=try decodeLimits(JSONSerialization.data(withJSONObject:limits))
        snapshot.continuityKey=SHA256.hash(data:binding).map{String(format:"%02x",$0)}.joined()
        return snapshot
    }
}
