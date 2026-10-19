import Foundation
import CryptoKit
import CoreFoundation

public enum NativeQuotaProvider: String, CaseIterable, Sendable {
    case codex, agy, claude
    public var title: String {self == .codex ? "Codex" : self == .agy ? "Antigravity CLI" : "Claude Code"}
}
/// Google's documented read-only print-mode command. Version gating prevents
/// an old CLI from interpreting the slash command as an inference prompt.
public enum AgyQuota {
    private static func number(_ value:Any?) -> Double? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else {return nil}
        return n.doubleValue
    }
    public static func supportedVersion(_ text:String) -> Bool {
        let parts=text.trimmingCharacters(in:.whitespacesAndNewlines).split(separator:".")
        guard parts.count==3,let major=Int(parts[0]),let minor=Int(parts[1]),let patch=Int(parts[2]) else {return false}
        return major>=1 && minor>=0 && patch>=0 && (major>1 || minor>1 || minor==1 && patch>=11)
    }
    public static func decode(_ data:Data,now:Date=Date()) throws -> NativeQuotaSnapshot {
        guard data.count<=2*1024*1024,
              let o=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let status=o["status"] as? String,status == "SUCCESS",
              number(o["num_turns"])==0,let usage=o["usage"] as? [String:Any],number(usage["total_tokens"])==0,
              let command=o["command"] as? [String:Any],let name=command["name"] as? String,["usage","/usage","quota","/quota"].contains(name),
              let body=command["data"] as? [String:Any],let groups=body["groups"] as? [[String:Any]],groups.count<=64 else {throw NativeQuotaError.invalidResponse}
        var windows=[NativeQuotaWindow](),seen=[Data:NativeQuotaWindow]();var complete=true
        let fractional=ISO8601DateFormatter();fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        for (i,group) in groups.enumerated() {
            guard let buckets=group["buckets"] as? [[String:Any]],buckets.count<=64 else {throw NativeQuotaError.invalidResponse}
            for (j,bucket) in buckets.enumerated() {
                guard let id=bucket["id"] as? String,!id.isEmpty,id.utf8.count<=256,
                      let period=bucket["window"] as? String,period.utf8.count<=64 else {throw NativeQuotaError.invalidResponse}
                if bucket["remaining_fraction"] == nil || bucket["remaining_fraction"] is NSNull {complete=false;continue}
                guard let remaining=number(bucket["remaining_fraction"]),(0...1).contains(remaining) else {throw NativeQuotaError.invalidResponse}
                var reset:Date?
                if let value=bucket["reset_time"],!(value is NSNull) {
                    guard let text=value as? String else {throw NativeQuotaError.invalidResponse}
                    if !text.isEmpty {
                        guard let time=fractional.date(from:text) ?? ISO8601DateFormatter().date(from:text) else {throw NativeQuotaError.invalidResponse}
                        reset=time
                    }
                }
                var label="额度组 \(i+1) · 窗口 \(j+1)"
                let suffix=["daily":"每日窗口","weekly":"每周窗口","monthly":"每月窗口"][period.lowercased()]
                if let suffix {label += " · "+suffix}
                let key=try JSONSerialization.data(withJSONObject:[id,period])
                let stable=SHA256.hash(data:key).map{String(format:"%02x",$0)}.joined()
                let value=NativeQuotaWindow(id:"agy-"+stable,title:label,usedPercent:(1-remaining)*100,durationMinutes:nil,resetsAt:reset)
                if let previous=seen[key] {
                    guard previous.usedPercent==value.usedPercent,previous.resetsAt==value.resetsAt else {throw NativeQuotaError.invalidResponse}
                    continue
                }
                seen[key]=value;windows.append(value)
            }
        }
        guard !windows.isEmpty,windows.count<=256 else {throw NativeQuotaError.unsupportedAccount}
        return NativeQuotaSnapshot(capturedAt:now,windows:windows,coverageComplete:complete)
    }
    public static func fetch(executable:String) throws -> NativeQuotaSnapshot {
        guard executable.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:executable) else {throw NativeQuotaError.launchFailed}
        let settings=CollectorSettings(executable:executable,configuration:"",stateDirectory:NSTemporaryDirectory())
        let version=try LocalCollector.execute(settings,arguments:["--version"],timeout:5,workingDirectory:NSTemporaryDirectory(),inheritSSHAgent:false,outputLimit:4096)
        guard let text=String(data:version,encoding:.utf8),supportedVersion(text) else {throw NativeQuotaError.unsupportedVersion}
        let data=try LocalCollector.execute(settings,arguments:["-p","/usage","--output-format","json","--print-timeout","15s"],timeout:20,workingDirectory:NSTemporaryDirectory(),inheritSSHAgent:false,outputLimit:2*1024*1024)
        return try decode(data)
    }
}
