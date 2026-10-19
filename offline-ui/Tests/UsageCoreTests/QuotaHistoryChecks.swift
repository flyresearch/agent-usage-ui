import Foundation
import UsageCore

func quotaHistoryChecks(_ check:(String,() throws -> Void)->Void) {
    let origin=Date(timeIntervalSince1970:1767225600)
    func snapshot(_ second:Double,_ used:Double,account:String?="fixture-account",reset:Double=3600,key:String="a") throws -> NativeQuotaSnapshot {
        let data=try JSONSerialization.data(withJSONObject:["rateLimitsByLimitId":[key:["primary":["usedPercent":used,"windowDurationMins":60,"resetsAt":origin.timeIntervalSince1970+reset]]]])
        var value=try CodexQuota.decodeLimits(data,now:origin.addingTimeInterval(second));value.continuityKey=account;return value
    }
    check("quota_history_verified_trend_and_no_early_prediction") {
        var h=NativeQuotaHistory()
        for (time,used) in [(0.0,10.0),(150,15),(300,20)] {
            let s=try snapshot(time,used);h.record(s,provider:.codex,now:s.capturedAt)
        }
        let trend=NativeQuotaHistory.trend(h.points,now:origin.addingTimeInterval(300))
        try require(trend?.percentagePointsPerHour==120 && trend?.sampleCount==3 && trend?.exhaustedAt==origin.addingTimeInterval(2700))
        try require(NativeQuotaHistory.trend(Array(h.points.prefix(2)),now:origin.addingTimeInterval(150))==nil)
        try require(NativeQuotaHistory.trend(h.points,now:origin.addingTimeInterval(391))==nil)
        let encoded=String(data:try h.encoded(),encoding:.utf8)!
        try require(!encoded.contains("fixture-account") && !encoded.contains("continuityKey"))
    }
    check("quota_history_flat_samples_do_not_predict_exhaustion") {
        var h=NativeQuotaHistory()
        for t in [0.0,150,300] {let s=try snapshot(t,20);h.record(s,provider:.codex,now:s.capturedAt)}
        let trend=NativeQuotaHistory.trend(h.points,now:origin.addingTimeInterval(300))
        try require(trend?.percentagePointsPerHour==0 && trend?.exhaustedAt==nil)
    }
    check("quota_history_breaks_on_identity_reset_drop_gap_failure_restart") {
        for mode in 0..<6 {
            var h=NativeQuotaHistory()
            let first=try snapshot(0,20);h.record(first,provider:.codex,now:first.capturedAt)
            if mode==4 {h.breakContinuity(.codex)}
            if mode==5 {h=try NativeQuotaHistory(data:h.encoded(),now:origin)}
            let next=try snapshot(mode==3 ? 301:60,mode==2 ? 10:25,account:mode==0 ? "other":"fixture-account",reset:mode==1 ? 4000:3600)
            h.record(next,provider:.codex,now:next.capturedAt)
            try require(h.points.count==2 && h.points[0].segment != h.points[1].segment)
        }
    }
    check("quota_history_duplicate_unknown_scope_and_clock_regression") {
        var h=NativeQuotaHistory()
        for t in [0.0,150,300] {
            let s=try snapshot(t,20,account:nil);h.record(s,provider:.claude,now:s.capturedAt);h.record(s,provider:.claude,now:s.capturedAt)
        }
        try require(h.points.count==3 && Set(h.points.map(\.segment)).count==3 && NativeQuotaHistory.trend(h.points,now:origin.addingTimeInterval(300))==nil)
        var c=NativeQuotaHistory()
        for t in [100.0,90,120] {let s=try snapshot(t,20);c.record(s,provider:.codex,now:s.capturedAt)}
        try require(c.points.count==2 && c.points[0].segment != c.points[1].segment)
    }
    check("quota_history_window_ids_survive_group_insertion") {
        let one=try snapshot(0,20,key:"b")
        let raw:[String:Any]=["rateLimitsByLimitId":["a":["primary":["usedPercent":0]],"b":["primary":["usedPercent":20,"windowDurationMins":60,"resetsAt":1767229200]]]]
        let two=try CodexQuota.decodeLimits(JSONSerialization.data(withJSONObject:raw),now:origin)
        try require(one.windows[0].id==two.windows[1].id)
    }
    check("quota_archive_lock_permissions_restart_and_corruption") {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        var archive:NativeQuotaArchive?=try NativeQuotaArchive(directory:dir,now:origin)
        let s=try snapshot(0,20);try archive!.record(s,provider:.codex,now:origin)
        try rejects {_=try NativeQuotaArchive(directory:dir,now:origin)}
        let file=dir.appendingPathComponent("quota-history.json")
        let attrs=try FileManager.default.attributesOfItem(atPath:file.path)
        try require((attrs[.posixPermissions] as? NSNumber)?.intValue==0o600)
        archive=nil
        var reopened:NativeQuotaArchive?=try NativeQuotaArchive(directory:dir,now:origin.addingTimeInterval(60))
        let next=try snapshot(60,25);try reopened!.record(next,provider:.codex,now:next.capturedAt)
        try require(reopened!.history.points.count==2 && reopened!.history.points[0].segment != reopened!.history.points[1].segment)
        reopened=nil
        try Data("corrupt".utf8).write(to:file)
        try rejects {_=try NativeQuotaArchive(directory:dir,now:origin)}
        try require(try String(contentsOf:file,encoding:.utf8)=="corrupt")
    }
    check("quota_history_retention_and_invalid_percentage") {
        var h=NativeQuotaHistory();let s=try snapshot(0,20);h.record(s,provider:.codex,now:origin)
        let expired=try NativeQuotaHistory(data:h.encoded(),now:origin.addingTimeInterval(8*86400));try require(expired.points.isEmpty)
        var data=try JSONSerialization.jsonObject(with:h.encoded()) as! [String:Any]
        var points=data["points"] as! [[String:Any]];points[0]["used"]=101;data["points"]=points
        try rejects {_=try NativeQuotaHistory(data:JSONSerialization.data(withJSONObject:data),now:origin)}
    }
}
