import Foundation
import UsageCore

/// Synthetic checks call the same projection used by the original Syrtis views.
enum FleetProjectionCheck {
    static func run() async -> Int32 {
        do {
            let zero:[String:Any]=["input":0,"cache_read":0,"cache_write":0,"output":0,"reasoning":0]
            var first=zero;first["input"]=10;first["cache_read"]=90
            var second=zero;second["output"]=7
            var total=first;total["output"]=7
            let fixture:[String:Any]=["schema_version":1,"host_id":"fixture","configuration_fingerprint":String(repeating:"a",count:64),"generated_at":"2026-01-01T00:00:00Z","timezone":"Asia/Singapore","complete":true,"coverage_complete":false,"sources":[["source_id":"main","status":"partial","files":2,"cache_hits":0,"coverage":[:]]],"totals":total,"rows":[["source_id":"main","agent":"codex","model":"example-model","day":"2026-01-01","time_basis":"event_timestamp","tokens":first],["source_id":"main","agent":"hermes","model":"other-model","day":NSNull(),"time_basis":"unallocated","tokens":second]]]
            let snapshot=try UsageSnapshot.decode(JSONSerialization.data(withJSONObject:fixture))
            let source=FleetUsageDataSource()
            let graph=try await source.projectGraph(.local(snapshot),year:nil)
            guard graph.summary.totalTokens==107,graph.contributions.count==1,graph.contributions[0].totals.tokens==100,graph.contributions[0].tokenBreakdown.cacheRead==90 else {throw FleetSourceError.unavailable}
            let year=try await source.projectGraph(.local(snapshot),year:"2026")
            guard year.summary.totalTokens==100 else {throw FleetSourceError.unavailable}
            let report=try await source.projectModels(.local(snapshot),year:nil)
            guard report.entries.count==2,report.entries.reduce(0,{$0+$1.total})==107,report.totalCacheRead==90 else {throw FleetSourceError.unavailable}
            let empty=try await source.projectGraph(.local(snapshot),year:"2025")
            guard empty.summary.totalTokens==0,empty.contributions.isEmpty else {throw FleetSourceError.unavailable}
            do {_=try await source.tokensPerMin();throw FleetSourceError.unavailable} catch FleetSourceError.unsupported {}
            var host:[String:Any]=["host_id":"fixture","state":"stale","included":true,"last_success_at":"2026-01-01T00:00:00Z","last_attempt_at":"2026-01-01T00:00:00Z","error":"collection_failed","snapshot":fixture]
            let envelope:[String:Any]=["schema_version":1,"kind":"fleet_snapshot","configuration_fingerprint":String(repeating:"b",count:64),"generated_at":"2026-01-01T00:00:00Z","complete":false,"coverage_complete":false,"totals":total,"hosts":[host]]
            let fleet=try FleetSnapshot.decode(JSONSerialization.data(withJSONObject:envelope))
            let retained=try await source.projectGraph(.fleet(fleet),year:nil)
            guard retained.summary.totalTokens==107 else {throw FleetSourceError.unavailable}
            let excluded=FleetUsageDataSource(selectedHost:{"absent"})
            do {_=try await excluded.projectGraph(.fleet(fleet),year:nil);throw FleetSourceError.outOfRange} catch FleetSourceError.unavailable {}
            host["state"]="configuration_changed";host["included"]=false
            var changed=envelope;changed["hosts"]=[host];changed["totals"]=NSNull()
            let fenced=try FleetSnapshot.decode(JSONSerialization.data(withJSONObject:changed))
            do {_=try await source.projectGraph(.fleet(fenced),year:nil);throw FleetSourceError.outOfRange} catch FleetSourceError.unavailable {}
            var pricedFixture=fixture
            var pricedRows=fixture["rows"] as! [[String:Any]]
            pricedRows[0]["model"]="gpt-5.1";pricedRows[0]["messages"]=["known":3,"complete":true]
            pricedFixture["rows"]=pricedRows
            let priced=try UsageSnapshot.decode(JSONSerialization.data(withJSONObject:pricedFixture))
            let pricedGraph=try await source.projectGraph(.local(priced),year:nil)
            let pricedModels=try await source.projectModels(.local(priced),year:nil)
            guard abs(pricedGraph.summary.totalCost-0.00002375)<0.00000000001,pricedGraph.contributions[0].totals.messages==3,pricedModels.totalMessages==3,abs(pricedGraph.summary.averagePerDay-0.00002375)<0.00000000001,abs(pricedGraph.summary.maxCostInSingleDay-0.00002375)<0.00000000001 else {throw FleetSourceError.unavailable}
            var wbFixture=pricedFixture
            pricedRows[0]["agent"]="workbuddy";wbFixture["rows"]=pricedRows
            let wb=try UsageSnapshot.decode(JSONSerialization.data(withJSONObject:wbFixture))
            let wbGraph=try await source.projectGraph(.local(wb),year:nil)
            let wbModels=try await source.projectModels(.local(wb),year:nil)
            guard wbGraph.summary.clients.contains("workbuddy"),wbModels.entries.contains(where:{$0.client=="workbuddy" && $0.total==100}),wbGraph.contributions[0].totals.messages==3 else {throw FleetSourceError.unavailable}
            print("{\"passed\":10,\"failed\":[]}");return 0
        } catch {print("{\"passed\":0,\"failed\":[\"fleet_projection\"]}");return 1}
    }
}

extension FleetProjectionCheck {
    static func runFile(_ path:String) async -> Int32 {
        do {
            let fleet=try FleetSnapshot.decode(Data(contentsOf:URL(fileURLWithPath:path)))
            let source=FleetUsageDataSource(selectedHost:{nil})
            let graph=try await source.projectGraph(.fleet(fleet),year:nil)
            let models=try await source.projectModels(.fleet(fleet),year:nil)
            let rows=fleet.selected();let count=try MessageCount.total(rows)
            let cost=try PriceCatalog.bundled().summary(rows)
            guard UInt64(graph.summary.totalTokens)==(try fleet.totals?.total),models.totalMessages==Int(exactly:count.known),abs(models.totalCost-(cost.doubleValue ?? 0))<0.000001 else {throw FleetSourceError.unavailable}
            let coverage = CoverageReport(fleet:fleet,snapshot:nil)
            let result:[String:Any]=["ok":true,"coverage_diagnostics_available":coverage.available,"coverage_complete":coverage.complete,"coverage_gap_sources":coverage.sources.filter(\.hasGap).count,"hosts":fleet.hosts.count,"fresh_hosts":fleet.hosts.filter{$0.state=="fresh"}.count,"message_count_available":count.known>0,"message_coverage_complete":count.complete,"cost_available":cost.usd != nil,"pricing_version":cost.version,"priced_tokens_percent":cost.totalTokens>0 ? Double(cost.pricedTokens)/Double(cost.totalTokens)*100:100]
            print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!);return 0
        } catch {print("{\"ok\":false,\"error\":\"fleet_metrics_check_failed\"}");return 1}
    }
}
