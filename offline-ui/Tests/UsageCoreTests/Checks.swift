import Foundation
import UsageCore

enum CheckFailure:Error {case failed}
func require(_ ok:Bool) throws {if !ok {throw CheckFailure.failed}}
func rejects(_ body:() throws -> Void) throws {
    do {try body()} catch {return}
    throw CheckFailure.failed
}
func fixture()->[String:Any] {
    let zero:[String:UInt64]=["input":0,"cache_read":0,"cache_write":0,"output":0,"reasoning":0]
    var first=zero;first["input"]=10;first["cache_read"]=100;first["output"]=5
    var second=zero;second["input"]=20;second["output"]=2
    var sum=zero;sum["input"]=30;sum["cache_read"]=100;sum["output"]=7
    return ["schema_version":1,"host_id":"synthetic-host","configuration_fingerprint":String(repeating:"a",count:64),"generated_at":"2026-01-01T00:00:00Z","timezone":"Asia/Singapore","complete":true,"coverage_complete":false,"totals":sum,
            "sources":[["source_id":"main","status":"partial","files":2,"cache_hits":0,"coverage":["missing_time_records":1]]],
            "rows":[["source_id":"main","agent":"codex","model":"model-a","day":"2026-01-01","time_basis":"event_timestamp","tokens":first],["source_id":"main","agent":"claude","model":"model-b","day":NSNull(),"time_basis":"unallocated","tokens":second]]]
}
func decode(_ value:[String:Any]) throws ->UsageSnapshot {try UsageSnapshot.decode(JSONSerialization.data(withJSONObject:value))}
func fleetFixture()->[String:Any] {
    let snapshot=fixture()
    let host:[String:Any]=["host_id":"synthetic-host","state":"fresh","included":true,"last_success_at":"2026-01-01T00:00:00Z","last_attempt_at":"2026-01-01T00:00:00Z","error":NSNull(),"snapshot":snapshot]
    return ["schema_version":1,"kind":"fleet_snapshot","configuration_fingerprint":String(repeating:"a",count:64),"generated_at":"2026-01-01T00:00:00Z","complete":true,"coverage_complete":false,"totals":snapshot["totals"]!,"hosts":[host]]
}
func decodeFleet(_ value:[String:Any]) throws ->FleetSnapshot {try FleetSnapshot.decode(JSONSerialization.data(withJSONObject:value))}
@main struct UsageCoreCheck {
    static func main() throws {
        var passed=0;var failures=[String]()
        func check(_ name:String,_ body:() throws ->Void) {do {try body();passed+=1} catch {failures.append(name)}}
        check("menu_date_scope_and_unallocated") {
            let snapshot=try decode(fixture())
            let now=ISO8601DateFormatter().date(from:"2025-12-31T16:30:00Z")!
            let today=try MenuSummary(fleet:nil,snapshot:snapshot,period:.today,now:now)
            try require(today.tokens?.total==115 && today.unallocated==22)
            try require(today.agents.map(\.id)==["codex"])
            let all=try MenuSummary(fleet:nil,snapshot:snapshot,agent:"claude",period:.all,now:now)
            try require(all.tokens?.total==22 && all.days.isEmpty)
            try require(MenuPeriod.week.bounds(now:now).0=="2025-12-26")
            try require(MenuPeriod.month.bounds(now:now).0=="2025-12-03")
        }
        check("menu_missing_is_not_zero_and_stale_retained") {
            let missing=try MenuSummary(fleet:nil,snapshot:nil,period:.today)
            try require(missing.tokens==nil)
            var value=fleetFixture();var hosts=value["hosts"] as! [[String:Any]]
            hosts[0]["state"]="stale";hosts[0]["error"]="collection_failed";value["hosts"]=hosts;value["complete"]=false
            let fleet=try decodeFleet(value)
            try require(MenuSummary(fleet:fleet,snapshot:nil,period:.all).tokens?.total==137)
            try require(MenuSummary(fleet:fleet,snapshot:nil,host:"absent",period:.all).tokens==nil)
            let empty=try MenuSummary(fleet:fleet,snapshot:nil,agent:"hermes",period:.all)
            try require(empty.tokens?.total==0)
        }
        check("price_known_unknown_and_cache_rate_coverage") {
            let rates:[String:Any] = ["schema_version":1,"version":"fixture-v1","currency":"USD","basis":"current-list-short-context-5m-cache-peak","rates":["model-a":["input":"1","cache_read":"0.1","cache_write":NSNull(),"output":"2","reasoning":"2","source":"https://example.com/prices"]]]
            let catalog=try PriceCatalog.decode(JSONSerialization.data(withJSONObject:rates))
            let snapshot=try decode(fixture());let estimate=try catalog.summary(snapshot.rows)
            try require(estimate.usd==Decimal(string:"0.00003") && estimate.pricedTokens==115 && estimate.totalTokens==137 && !estimate.complete)
            try require(catalog.estimate(snapshot.rows[1])==nil)
            var v=fixture();var rows=v["rows"] as! [[String:Any]];var tokens=rows[0]["tokens"] as! [String:UInt64];tokens["cache_write"]=1;rows[0]["tokens"]=tokens;v["rows"]=rows;var total=v["totals"] as! [String:UInt64];total["cache_write"]=1;v["totals"]=total
            try require(catalog.estimate(decode(v).rows[0])==nil)
            var bad=rates;bad["currency"]="EUR";try rejects {_=try PriceCatalog.decode(JSONSerialization.data(withJSONObject:bad))}
            try require(!PriceCatalog.bundled().rates.isEmpty)
        }
        check("message_partial_coverage_and_overflow") {
            let old=try decode(fixture());try require(MessageCount.total(old.rows)==MessageCount())
            var v=fixture();var rows=v["rows"] as! [[String:Any]];rows[0]["messages"]=["known":2,"complete":true];v["rows"]=rows
            let s=try decode(v);try require(MessageCount.total(s.rows)==MessageCount(known:2,complete:false));try require(MessageCount.total(s.selected(agent:"codex"))==MessageCount(known:2,complete:true))
            try rejects {_=try MessageCount(known:UInt64.max,complete:true).adding(MessageCount(known:1,complete:true))}
        }
        check("owned_bundle_collector_follows_app_upgrade_but_custom_cli_does_not") {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
            let old=root.appendingPathComponent("Old.app/Contents/MacOS/agent-usage"),new=root.appendingPathComponent("New.app/Contents/MacOS/agent-usage")
            for exe in [old,new] {try FileManager.default.createDirectory(at:exe.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("fixture".utf8).write(to:exe);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:exe.path)}
            let plist=old.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
            try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"org.flyresearch.agentusage"],format:.xml,options:0).write(to:plist)
            let settings=CollectorSettings(executable:old.path,configuration:"/fixture/config",stateDirectory:"/fixture/state")
            try require(LocalCollector.reboundSettings(settings,currentExecutable:new).executable==new.path)
            try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"example.custom"],format:.xml,options:0).write(to:plist)
            try require(LocalCollector.reboundSettings(settings,currentExecutable:new).executable==old.path)
            var custom=settings;custom.executable="/fixture/custom-cli"
            try require(LocalCollector.reboundSettings(custom,currentExecutable:new).executable==custom.executable)
            try require(LocalCollector.reboundSettings(settings,currentExecutable:nil).executable==old.path)
        }
        check("workbuddy_decode_filter_and_count") {
            var v=fixture();var rows=v["rows"] as! [[String:Any]]
            rows[0]["agent"]="workbuddy";rows[0]["messages"]=["known":2,"complete":true];v["rows"]=rows
            let snapshot=try decode(v);let selected=snapshot.selected(agent:"workbuddy")
            try require(selected.count==1 && UsageSnapshot.total(selected).total==115)
            try require(MessageCount.total(selected)==MessageCount(known:2,complete:true))
        }
        check("hour_role_fields_validate_and_legacy_rows_remain_unknown") {
            var v=fixture();var rows=v["rows"] as! [[String:Any]]
            let old=try decode(v);try require(old.rows.allSatisfy{$0.hour==nil && $0.execution_role==nil})
            rows[0]["hour"]=8;rows[0]["execution_role"]="main";v["rows"]=rows
            let current=try decode(v);try require(current.rows[0].hour==8 && current.rows[0].execution_role=="main")
            for invalid in [-1,24] {rows[0]["hour"]=invalid;v["rows"]=rows;try rejects {_=try decode(v)}}
            rows[0]["hour"]=8;rows[0]["execution_role"]="private-name";v["rows"]=rows;try rejects {_=try decode(v)}
            rows[0]["execution_role"]="main";rows[1]["hour"]=0;v["rows"]=rows;try rejects {_=try decode(v)}
        }
        check("filter_before_sum") {
            let s=try decode(fixture());try require(s.totals.total==137)
            try require(UsageSnapshot.total(s.selected(agent:"codex")).total==115)
            try require(UsageSnapshot.total(s.selected(model:"model-b")).total==22)
            try require(UsageSnapshot.total(s.selected(start:"2026-01-01",end:"2026-01-01")).total==115)
            try require(s.selected(start:"2026-01-02").isEmpty)
        }
        check("reject_total_mismatch") {var v=fixture();v["totals"]=["input":0,"cache_read":0,"cache_write":0,"output":0,"reasoning":0];try rejects {_=try decode(v)}}
        check("reject_incomplete_and_version") {for field in ["complete","schema_version"] {var v=fixture();v[field]=field=="complete" ? false : 99;try rejects {_=try decode(v)}}}
        check("reject_invalid_date_and_label") {for field in ["day","model"] {var v=fixture();var rows=v["rows"] as! [[String:Any]];rows[0][field]=field=="day" ? "2026-99-99" : "private@example.invalid";v["rows"]=rows;try rejects {_=try decode(v)}}}
        check("reject_invalid_generated_time") {var v=fixture();v["generated_at"]="invalid-time";try rejects {_=try decode(v)}}
        check("reject_duplicate_source") {var v=fixture();let sources=v["sources"] as! [[String:Any]];v["sources"]=sources+sources;try rejects {_=try decode(v)}}
        check("reject_unknown_source") {var v=fixture();v["sources"]=[] as [[String:Any]];try rejects {_=try decode(v)}}
        check("reject_overflow") {try rejects {_=try Tokens(input:UInt64.max,cache_read:1).total};try rejects {_=try Tokens(input:UInt64.max).adding(Tokens(output:1))}}
        check("hermes_interval_decode_and_filter") {
            var v=fixture();var rows=v["rows"] as! [[String:Any]]
            rows[0]["agent"]="hermes";rows[0]["time_basis"]="aggregate_interval";rows[0]["usage_kind"]="main"
            rows[0]["interval"]=["start":"2026-01-01T00:00:00Z","end":"2026-01-01T01:00:00Z"]
            rows[1]["agent"]="hermes";rows[1]["time_basis"]="unallocated_interval";rows[1]["usage_kind"]="auxiliary"
            rows[1]["interval"]=["start":"2026-01-01T00:00:00Z","end":"2026-01-02T00:00:00Z"]
            v["rows"]=rows;let s=try decode(v)
            try require(UsageSnapshot.total(s.selected(agent:"hermes")).total==137)
            try require(UsageSnapshot.total(s.selected(start:"2026-01-01",end:"2026-01-01")).total==115)
            for bad in ["garbage","2025-12-31T00:00:00Z","2026-01-02T00:00:00Z"] {
                rows[0]["interval"]=["start":"2026-01-01T00:00:00Z","end":bad];v["rows"]=rows
                try rejects {_=try decode(v)}
            }
        }
        check("fleet_filter_before_aggregation") {
            var v=fleetFixture();var hosts=v["hosts"] as! [[String:Any]]
            var other=hosts[0];other["host_id"]="second-host";var snapshot=fixture();snapshot["host_id"]="second-host";other["snapshot"]=snapshot;hosts.append(other);v["hosts"]=hosts
            v["totals"]=["input":60,"cache_read":200,"cache_write":0,"output":14,"reasoning":0]
            let f=try decodeFleet(v)
            try require(f.totals?.total==274)
            try require(UsageSnapshot.total(f.selected(host:"second-host",agent:"codex")).total==115)
            try require(UsageSnapshot.total(f.selected(start:"2026-01-01",end:"2026-01-01")).total==230)
        }
        check("fleet_missing_and_changed_hosts_are_not_zero") {
            for state in ["never_collected","configuration_changed"] {
                var v=fleetFixture();var hosts=v["hosts"] as! [[String:Any]];hosts[0]["state"]=state;hosts[0]["included"]=false
                if state=="never_collected" {hosts[0]["snapshot"]=NSNull();hosts[0]["last_success_at"]=NSNull()}
                v["hosts"]=hosts;v["totals"]=NSNull();v["complete"]=false
                let f=try decodeFleet(v);try require(f.totals==nil && !f.hasData() && f.selected().isEmpty)
            }
        }
        check("fleet_stale_snapshot_stays_included") {
            var v=fleetFixture();var hosts=v["hosts"] as! [[String:Any]];hosts[0]["state"]="stale";hosts[0]["error"]="collection_timeout";v["hosts"]=hosts;v["complete"]=false
            let f=try decodeFleet(v);try require(f.hasData());try require(f.totals?.total==137)
        }
        check("fleet_rejects_mismatch_and_invalid_nested_snapshot") {
            for field in ["host_id","included","state","snapshot"] {
                var v=fleetFixture();var hosts=v["hosts"] as! [[String:Any]]
                switch field {case "host_id":hosts[0][field]="wrong";case "included":hosts[0][field]=false;case "state":hosts[0][field]="unknown";default:var snapshot=fixture();snapshot["complete"]=false;hosts[0][field]=snapshot}
                v["hosts"]=hosts;try rejects {_=try decodeFleet(v)}
            }
            var v=fleetFixture();v["totals"]=NSNull();try rejects {_=try decodeFleet(v)}
        }
        check("process_deadline_survives_ignored_term_and_inherited_stdout") {
            let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:dir)}
            let settings=CollectorSettings(executable:"/bin/sh",configuration:"",stateDirectory:dir.path)
            for command in ["trap '' TERM; exec sleep 2", "sleep 1 & exit 0"] {
                let start=ProcessInfo.processInfo.systemUptime
                do {_=try LocalCollector.execute(settings,arguments:["-c",command],timeout:0.08);throw CheckFailure.failed}
                catch UsageError.timedOut {}
                try require(ProcessInfo.processInfo.systemUptime-start<1)
            }
        }
        check("process_output_is_bounded") {
            let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:dir)}
            let settings=CollectorSettings(executable:"/usr/bin/yes",configuration:"",stateDirectory:dir.path)
            do {_=try LocalCollector.execute(settings,arguments:[],timeout:5);throw CheckFailure.failed}
            catch UsageError.outputTooLarge {}
        }
        check("configuration_change_is_not_restored_as_current_data") {
            let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:dir)}
            let settings=CollectorSettings(executable:"/bin/sh",configuration:"",stateDirectory:dir.path)
            do {_=try LocalCollector.execute(settings,arguments:["-c","printf '{\"error\":\"fleet_configuration_changed\"}'; exit 1"],timeout:1);throw CheckFailure.failed}
            catch UsageError.configurationChanged {}
        }
        check("fleet_source_failure_is_controlled_and_requires_error") {
            var v=fleetFixture();var hosts=v["hosts"] as! [[String:Any]]
            hosts[0]["failed_source_id"]="main";v["hosts"]=hosts;try rejects {_=try decodeFleet(v)}
            hosts[0]["state"]="stale";hosts[0]["error"]="source_missing";v["hosts"]=hosts;v["complete"]=false
            let f=try decodeFleet(v);try require(f.hosts[0].failed_source_id=="main");try require(f.totals?.total==137)
            hosts[0]["failed_source_id"]="private@example.invalid";v["hosts"]=hosts;try rejects {_=try decodeFleet(v)}
        }
        if let binary=ProcessInfo.processInfo.environment["AGENT_USAGE_TEST_COLLECTOR"] {
            check("local_restore_is_bound_to_current_real_collector_configuration") {
                let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer {try? FileManager.default.removeItem(at:root)}
                let logs=root.appendingPathComponent("logs");try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
                let record="{\"type\":\"event_msg\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":10,\"output_tokens\":2}}}}\n"
                let log=logs.appendingPathComponent("a.jsonl");try Data(record.utf8).write(to:log)
                let config=root.appendingPathComponent("config.json")
                func writeConfig(_ host:String) throws {try JSONSerialization.data(withJSONObject:["schema_version":1,"host_id":host,"sources":[["id":"main","adapter":"codex-jsonl","paths":[logs.path]]]]).write(to:config,options:.atomic)}
                try writeConfig("scope-a")
                let settings=CollectorSettings(executable:binary,configuration:config.path,stateDirectory:root.appendingPathComponent("state").path)
                let first=try LocalCollector.refresh(settings);try require(first.totals.total==12);try require(LocalCollector.saved(settings).host_id=="scope-a")
                let saved=URL(fileURLWithPath:settings.stateDirectory).appendingPathComponent("snapshot.json");let prior=try Data(contentsOf:saved)
                try writeConfig("scope-b")
                do {_=try LocalCollector.saved(settings);throw CheckFailure.failed} catch UsageError.configurationChanged {}
                try Data("invalid JSON\n".utf8).write(to:log)
                do {_=try LocalCollector.refreshResult(settings,expectedLocalFingerprint:first.configuration_fingerprint);throw CheckFailure.failed} catch UsageError.configurationChanged {}
                try require(Data(contentsOf:saved)==prior)
                try Data(record.utf8).write(to:log);let second=try LocalCollector.refresh(settings);try require(second.host_id=="scope-b");try require(second.configuration_fingerprint != first.configuration_fingerprint);try require(LocalCollector.saved(settings).totals.total==12)
                try Data("invalid JSON\n".utf8).write(to:log)
                do {_=try LocalCollector.refreshResult(settings,expectedLocalFingerprint:second.configuration_fingerprint);throw CheckFailure.failed} catch UsageError.sourceFailure(let source) {try require(source=="main")}
                try require(LocalCollector.saved(settings).host_id=="scope-b")
            }
        }
        configurationChecks(check)
        liveChecks(check)
        let result:[String:Any]=["passed":passed,"failed":failures,"collector_integration":ProcessInfo.processInfo.environment["AGENT_USAGE_TEST_COLLECTOR"] == nil ? "not_requested" : "executed"]
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
        if !failures.isEmpty {exit(1)}
    }
}
