import Foundation
import CryptoKit
import CoreFoundation

public enum NativeQuotaProvider: String, CaseIterable, Sendable {
    case codex, agy, claude
    public var title: String {self == .codex ? "Codex" : self == .agy ? "Antigravity CLI" : "Claude Code"}
}
/// agy's grouped quota allowances. The app never runs `agy` to get them:
/// `agy --print /usage` opens a browser for interactive OAuth whenever its
/// silent keyring auth is slow, so the fleet lane reads the same groups through
/// the core's `tb_antigravity_direct_quota` (`decodeSummary`). `decode` keeps
/// accepting the CLI's JSON shape for fixtures and window-id continuity.
public enum AgyQuota {
    private static func number(_ value:Any?) -> Double? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else {return nil}
        return n.doubleValue
    }
    /// `agy --print /usage --output-format json` output.
    public static func decode(_ data:Data,now:Date=Date()) throws -> NativeQuotaSnapshot {
        guard data.count<=2*1024*1024,
              let o=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let status=o["status"] as? String,status == "SUCCESS",
              number(o["num_turns"])==0,let usage=o["usage"] as? [String:Any],number(usage["total_tokens"])==0,
              let command=o["command"] as? [String:Any],let name=command["name"] as? String,["usage","/usage","quota","/quota"].contains(name),
              let body=command["data"] as? [String:Any] else {throw NativeQuotaError.invalidResponse}
        return try decodeGroups(body,now:now)
    }
    /// `{"groups":[...]}` with the same bucket fields, from the core.
    public static func decodeSummary(_ data:Data,now:Date=Date()) throws -> NativeQuotaSnapshot {
        guard data.count<=2*1024*1024,let body=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {throw NativeQuotaError.invalidResponse}
        return try decodeGroups(body,now:now)
    }
    private static func decodeGroups(_ body:[String:Any],now:Date) throws -> NativeQuotaSnapshot {
        guard let groups=body["groups"] as? [[String:Any]],groups.count<=64 else {throw NativeQuotaError.invalidResponse}
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
}
