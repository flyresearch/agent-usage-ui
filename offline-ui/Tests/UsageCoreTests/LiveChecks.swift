import Foundation
import UsageCore

func liveChecks(_ check:(String,() throws -> Void)->Void) {
    let now=Date(timeIntervalSince1970:1767225600)
    func activityFixture()->[String:Any] {
        var s=fixture();s["recent_activity"]=["as_of":1767225600,"window_seconds":600,"coverage_complete":true,"unlocated_records":0,"future_records":0,"unsupported_sources":[],
            "buckets":[["timestamp":1767225595,"agent":"codex","tokens":100,"messages":["known":1,"complete":true]]]] as [String:Any]
        return s
    }
    check("recent_rate_missing_stale_and_partial_are_distinct_from_zero") {
        let s=try decode(activityFixture());let report=try LiveActivityReport(fleet:nil,snapshot:s,now:now)
        try require(report.rate==10 && report.available && report.complete)
        let stale=try LiveActivityReport(fleet:nil,snapshot:s,now:now.addingTimeInterval(76))
        try require(!stale.available && stale.rate==nil)
        let old=try LiveActivityReport(fleet:nil,snapshot:decode(fixture()),now:now)
        try require(old.rate==nil && !old.complete)
        var v=activityFixture();var a=v["recent_activity"] as! [String:Any];a["buckets"]=[] as [[String:Any]];v["recent_activity"]=a
        let zero=try LiveActivityReport(fleet:nil,snapshot:decode(v),now:now);try require(zero.rate==0 && zero.complete)
        a["coverage_complete"]=false;a["unlocated_records"]=1;v["recent_activity"]=a
        let partial=try LiveActivityReport(fleet:nil,snapshot:decode(v),now:now);try require(partial.rate==0 && !partial.complete)
    }
    check("recent_fleet_retained_sample_and_missing_hosts_remain_partial") {
        var f=fleetFixture();var hosts=f["hosts"] as! [[String:Any]]
        hosts[0]["snapshot"]=activityFixture();hosts[0]["state"]="stale";hosts[0]["error"]="collection_failed"
        f["hosts"]=hosts;f["complete"]=false
        let report=try LiveActivityReport(fleet:decodeFleet(f),snapshot:nil,now:now)
        try require(report.available && !report.complete && report.rate==10 && report.retainedHosts.count==1)
        let absent=try LiveActivityReport(fleet:decodeFleet(f),snapshot:nil,host:"absent",now:now)
        try require(!absent.available && absent.rate==nil)
    }
    check("recent_payload_validation_rejects_future_duplicate_and_inflated_buckets") {
        for mode in 0..<3 {
            var v=activityFixture();var a=v["recent_activity"] as! [String:Any];var b=(a["buckets"] as! [[String:Any]])[0]
            if mode==0 {b["timestamp"]=1767225601}
            if mode==1 {b["tokens"]=1000}
            a["buckets"]=mode==2 ? [b,b]:[b];v["recent_activity"]=a
            try rejects {_=try decode(v)}
        }
    }
    check("quota_multibucket_mapping_does_not_add_legacy_mirror_or_private_labels") {
        let window:[String:Any]=["usedPercent":25,"windowDurationMins":300,"resetsAt":1767229200]
        let limits:[String:Any]=["rateLimits":["primary":window],"rateLimitsByLimitId":["a":["limitName":"PRIVATE-NAME","primary":window],"b":["secondary":window]]]
        let snapshot=try CodexQuota.decodeLimits(JSONSerialization.data(withJSONObject:limits),now:now)
        try require(snapshot.windows.count==2 && snapshot.remaining(at:now)==75)
        try require(!snapshot.windows.contains{$0.title.contains("PRIVATE")})
        try require(snapshot.remaining(at:now.addingTimeInterval(91))==nil)
        for invalid in [-1,101] {try rejects {_=try CodexQuota.decodeLimits(JSONSerialization.data(withJSONObject:["rateLimits":["primary":["usedPercent":invalid]]]))}}
        try rejects {_=try CodexQuota.decodeLimits(Data("{\"rateLimitsByLimitId\":{}}".utf8))}
    }
    check("native_quota_rpc_uses_only_account_and_limits_and_checks_binding") {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        func executable(_ mode:String) throws -> URL {
            let file=root.appendingPathComponent("fake-codex-"+mode)
            let script="""
            #!/usr/bin/python3
            import json,sys,time
            mode=\(String(reflecting:mode))
            count=0
            allowed={'initialize','initialized','account/read','account/rateLimits/read'}
            for line in sys.stdin:
                m=json.loads(line)
                if m['method'] not in allowed: sys.exit(12)
                if m['method']=='initialized': continue
                result={}
                if m['method']=='account/read':
                    count+=1
                    result={'account':{'type':'chatgpt','email':'fixture-one' if count==1 or mode!='switch' else 'fixture-two'}}
                if m['method']=='account/rateLimits/read':
                    if mode=='timeout': time.sleep(5)
                    if mode=='error':
                        print(json.dumps({'id':m['id'],'error':{'message':'PRIVATE-SECRET'}}),flush=True);continue
                    result={'rateLimits':{'primary':{'usedPercent':25,'windowDurationMins':300,'resetsAt':int(time.time())+300}}}
                print(json.dumps({'id':m['id'],'result':result}),flush=True)
            """
            try Data(script.utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path);return file
        }
        let normal=try executable("normal");try require(CodexQuota.fetch(executable:normal.path).windows.count==1)
        for mode in ["switch","error"] {
            let file=try executable(mode)
            do {_=try CodexQuota.fetch(executable:file.path);throw CheckFailure.failed}
            catch NativeQuotaError.requestFailed {}
        }
        let timeout=try executable("timeout")
        do {_=try CodexQuota.fetch(executable:timeout.path,timeout:0.1);throw CheckFailure.failed}
        catch NativeQuotaError.timedOut {}
    }
    check("agy_readonly_response_validation_and_version_gate") {
        try require(AgyQuota.supportedVersion("1.4.2\n") && AgyQuota.supportedVersion("1.1.11"))
        try require(!AgyQuota.supportedVersion("1.1.10") && !AgyQuota.supportedVersion("unknown") && !AgyQuota.supportedVersion("1.-2.1"))
        let bucket:[String:Any] = ["id":"fixture", "name":"PRIVATE-NAME", "window":"weekly", "remaining_fraction":0.75,"reset_time":"2026-01-02T00:00:00Z"]
        func response(_ buckets:[[String:Any]],turns:Int=0) throws -> Data {
            try JSONSerialization.data(withJSONObject:["status":"SUCCESS","num_turns":turns,"usage":["total_tokens":0],"command":["name":"usage","data":["groups":[["buckets":buckets]]]]])
        }
        let value=try AgyQuota.decode(response([bucket,bucket]),now:now)
        try require(value.windows.count==1 && value.remaining(at:now)==75 && !value.windows[0].title.contains("PRIVATE"))
        var missing=bucket;missing["id"]="missing";missing["remaining_fraction"]=NSNull()
        let partial=try AgyQuota.decode(response([bucket,missing]),now:now)
        try require(!partial.coverageComplete && partial.remaining(at:now)==nil)
        try rejects {_=try AgyQuota.decode(response([bucket],turns:1),now:now)}
        var invalid=bucket;invalid["remaining_fraction"]=1.1
        try rejects {_=try AgyQuota.decode(response([invalid]),now:now)}
        invalid["remaining_fraction"]=false
        try rejects {_=try AgyQuota.decode(response([invalid]),now:now)}
        invalid["remaining_fraction"]=0.5
        try rejects {_=try AgyQuota.decode(response([bucket,invalid]),now:now)}
    }
    if let binary=ProcessInfo.processInfo.environment["AGENT_USAGE_TEST_AGY"] {
        check("explicit_native_agy_readonly_smoke") {
            let snapshot=try AgyQuota.fetch(executable:binary)
            try require(!snapshot.windows.isEmpty)
            print("{\"native_agy_quota\":true,\"windows\":\(snapshot.windows.count)}")
        }
    }
    if let binary=ProcessInfo.processInfo.environment["AGENT_USAGE_TEST_CODEX"] {
        check("explicit_native_codex_readonly_smoke") {
            let snapshot=try CodexQuota.fetch(executable:binary)
            try require(!snapshot.windows.isEmpty)
            print("{\"native_codex_quota\":true,\"windows\":\(snapshot.windows.count)}")
        }
    }
}
