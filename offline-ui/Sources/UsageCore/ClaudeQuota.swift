import Foundation
import CoreFoundation

/// Sanitized local output of the official Claude Code statusLine callback.
/// It describes the latest observed session, never an independently polled account.
public enum ClaudeQuota {
    private static func number(_ value:Any?) -> Double? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else {return nil}
        return n.doubleValue
    }
    public static func decode(_ data:Data,now:Date=Date()) throws -> NativeQuotaSnapshot {
        guard data.count<=16384,let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              number(value["schema_version"])==1,let captured=number(value["captured_at"]),
              let rows=value["windows"] as? [[String:Any]],rows.count<=2 else {throw NativeQuotaError.invalidResponse}
        let date=Date(timeIntervalSince1970:captured)
        guard (-5...90).contains(now.timeIntervalSince(date)) else {throw NativeQuotaError.staleSample}
        var seen=Set<String>(),windows=[NativeQuotaWindow]()
        for row in rows {
            guard let key=row["window"] as? String,["five_hour","seven_day"].contains(key),seen.insert(key).inserted,
                  let used=number(row["used_percentage"]),(0...100).contains(used),
                  let reset=number(row["resets_at"]),reset>0 else {throw NativeQuotaError.invalidResponse}
            windows.append(NativeQuotaWindow(id:"claude-"+key,title:key == "five_hour" ? "五小时窗口":"七天窗口",usedPercent:used,durationMinutes:key == "five_hour" ? 300:10080,resetsAt:Date(timeIntervalSince1970:reset)))
        }
        guard !windows.isEmpty else {throw NativeQuotaError.missingSample}
        return NativeQuotaSnapshot(capturedAt:date,windows:windows,coverageComplete:windows.count==2)
    }
    public static func fetch(path:String) throws -> NativeQuotaSnapshot {
        guard path.hasPrefix("/"),let file=FileHandle(forReadingAtPath:path) else {throw NativeQuotaError.missingSample}
        defer {try? file.close()}
        guard let data=try file.read(upToCount:16385) else {throw NativeQuotaError.missingSample}
        return try decode(data)
    }
}
