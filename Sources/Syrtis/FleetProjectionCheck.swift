import Foundation
import SwiftUI
import AppKit
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
            let legacyActivity=try await source.projectActivity(.local(snapshot),windowSecs:600)
            guard !legacyActivity.available,legacyActivity.rate==nil else {throw FleetSourceError.unavailable}
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
            var analysis=fixture
            var analysisRows=fixture["rows"] as! [[String:Any]]
            analysisRows[0]["hour"]=8;analysisRows[0]["execution_role"]="main"
            var child=analysisRows[0];child["agent"]="claude";child["execution_role"]="subagent"
            var childTokens=zero;childTokens["output"]=5;child["tokens"]=childTokens
            analysisRows.append(child);analysis["rows"]=analysisRows
            var analysisTotal=total;analysisTotal["output"]=12;analysis["totals"]=analysisTotal
            let a=try UsageSnapshot.decode(JSONSerialization.data(withJSONObject:analysis))
            let hours=try await source.projectHourly(.local(a),year:nil,clients:nil)
            guard hours.entries.count==1,hours.entries[0].total==105,hours.entries[0].hour=="2026-01-01 08:00",hours.unallocatedTokens==7,hours.hourCoverageComplete==false,hours.costEstimate==nil else {throw FleetSourceError.unavailable}
            let codexHours=try await source.projectHourly(.local(a),year:"2026",clients:["codex"])
            guard codexHours.entries[0].total==100,codexHours.unallocatedTokens==0,codexHours.hourCoverageComplete==true else {throw FleetSourceError.unavailable}
            let oldHours=try await source.projectHourly(.local(snapshot),year:nil,clients:nil)
            guard oldHours.entries.isEmpty,oldHours.unallocatedTokens==107,oldHours.hourCoverageComplete==false else {throw FleetSourceError.unavailable}
            let roles=try await source.projectAgents(.local(a),year:nil,clients:nil)
            guard roles.entries.count==3,roles.entries.reduce(0,{$0+$1.total})==112,roles.unclassifiedTokens==7,roles.costEstimate==nil else {throw FleetSourceError.unavailable}
            let childRole=try await source.projectAgents(.local(a),year:nil,clients:["claude"])
            guard childRole.entries.count==1,childRole.entries[0].agent=="subagent",childRole.entries[0].total==5 else {throw FleetSourceError.unavailable}
            let hiddenHours=try await source.projectHourly(.local(a),year:nil,clients:[])
            let hiddenAgents=try await source.projectAgents(.local(a),year:nil,clients:[])
            guard hiddenHours.entries.isEmpty,hiddenAgents.entries.isEmpty else {throw FleetSourceError.unavailable}
            let noYear=try await source.projectHourly(.local(a),year:"2025",clients:nil)
            guard noYear.entries.isEmpty,noYear.unallocatedTokens==0 else {throw FleetSourceError.unavailable}
            guard AppView.visible(hiddenRaw:"hourly,agents",fleet:true)==[.overview,.quota,.models,.monthly,.daily,.stats],
                AppView.effective(.hourly,hiddenRaw:"hourly",fleet:true) == .overview,
                AppView.effective(.quota,hiddenRaw:"",fleet:true) == .quota,
                AppView.visible(hiddenRaw:"",fleet:true).contains(.agents) else {throw FleetSourceError.unavailable}
            var secondAnalysis=analysis;secondAnalysis["host_id"]="second-host"
            func freshHost(_ id:String,_ snap:[String:Any]) -> [String:Any] {
                ["host_id":id,"state":"fresh","included":true,"last_success_at":"2026-01-01T00:00:00Z","last_attempt_at":"2026-01-01T00:00:00Z","snapshot":snap]
            }
            var doubled=zero;doubled["input"]=20;doubled["cache_read"]=180;doubled["output"]=24
            let multi:[String:Any]=["schema_version":1,"kind":"fleet_snapshot","configuration_fingerprint":String(repeating:"c",count:64),"generated_at":"2026-01-01T00:00:00Z","complete":true,"coverage_complete":false,"totals":doubled,"hosts":[freshHost("fixture",analysis),freshHost("second-host",secondAnalysis)]]
            let scopedSource=FleetUsageDataSource(selectedHost:{"fixture"})
            let multiFleet=try FleetSnapshot.decode(JSONSerialization.data(withJSONObject:multi))
            let scopedHours=try await scopedSource.projectHourly(.fleet(multiFleet),year:nil,clients:nil)
            let scopedRoles=try await scopedSource.projectAgents(.fleet(multiFleet),year:nil,clients:nil)
            guard scopedHours.entries[0].total==105,scopedRoles.entries.reduce(0,{$0+$1.total})==112 else {throw FleetSourceError.unavailable}
            var split=analysis;var splitRows=analysisRows
            var half=zero;half["input"]=5;half["cache_read"]=45
            splitRows[0]["tokens"]=half;var another=splitRows[0];another["hour"]=9;splitRows.append(another);split["rows"]=splitRows
            let splitSnapshot=try UsageSnapshot.decode(JSONSerialization.data(withJSONObject:split))
            let splitGraph=try await source.projectGraph(.local(splitSnapshot),year:nil)
            guard splitGraph.contributions[0].clients.count==2,
                splitGraph.contributions[0].clients.first(where:{$0.client=="codex"})?.tokens.total==100 else {throw FleetSourceError.unavailable}
            try await FleetAnalysisCheck.run(oldHours:hours,newHours:codexHours,oldAgents:roles,newAgents:childRole)
            print("{\"passed\":22,\"failed\":[]}");return 0
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
            let hours=try await source.projectHourly(.fleet(fleet),year:nil,clients:nil)
            let agents=try await source.projectAgents(.fleet(fleet),year:nil,clients:nil)
            guard hours.entries.reduce(0,{$0+$1.total})+(hours.unallocatedTokens ?? 0)==graph.summary.totalTokens,
                  agents.entries.reduce(0,{$0+$1.total})==graph.summary.totalTokens else {throw FleetSourceError.unavailable}
            let coverage = CoverageReport(fleet:fleet,snapshot:nil)
            let result:[String:Any]=["ok":true,"hourly_entries":hours.entries.count,"hourly_coverage_complete":hours.hourCoverageComplete ?? false,"agent_groups":agents.entries.count,"coverage_diagnostics_available":coverage.available,"coverage_complete":coverage.complete,"coverage_gap_sources":coverage.sources.filter(\.hasGap).count,"hosts":fleet.hosts.count,"fresh_hosts":fleet.hosts.filter{$0.state=="fresh"}.count,"message_count_available":count.known>0,"message_coverage_complete":count.complete,"cost_available":cost.usd != nil,"pricing_version":cost.version,"priced_tokens_percent":cost.totalTokens>0 ? Double(cost.pricedTokens)/Double(cost.totalTokens)*100:100]
            print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!);return 0
        } catch {print("{\"ok\":false,\"error\":\"fleet_metrics_check_failed\"}");return 1}
    }
}


extension FleetProjectionCheck {
    /// Render the production selector with synthetic IDs, without launching the
    /// app runtime or reading provider snapshots. Useful for visual layout QA.
    @MainActor static func renderSources(directory:String) -> Int32 {
        let clients=["agy","codex","claude","hermes","openclaw","workbuddy"]
        do {
            for dark in [false,true] {
                for selected in ["overview","claude"] {
                    let view=DashboardTabs(clients:clients,presentClients:clients,active:.constant(selected))
                        .padding(12).frame(width:PopoverChrome.width)
                        .background(dark ? Color(red:0.13,green:0.13,blue:0.14):Color(red:0.96,green:0.96,blue:0.97))
                        .environment(\.colorScheme,dark ? .dark:.light)
                    let renderer=ImageRenderer(content:view);renderer.scale=2
                    guard let image=renderer.cgImage,
                          let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {return 1}
                    try data.write(to:URL(fileURLWithPath:directory).appendingPathComponent("sources-\(dark ? "dark":"light")-\(selected).png"))
                }
            }
            return 0
        } catch {return 1}
    }
}

extension FleetProjectionCheck {
    @MainActor static func renderQuotaHistory(directory:String) -> Int32 {
        do {
            let now=Date(),reset=Int(now.timeIntervalSince1970)+3600
            var history=NativeQuotaHistory(),latest:NativeQuotaSnapshot?
            for i in 0...18 {
                let data=try JSONSerialization.data(withJSONObject:["rateLimits":["primary":["usedPercent":10+i*2,"windowDurationMins":60,"resetsAt":reset]]])
                var snapshot=try CodexQuota.decodeLimits(data,now:now.addingTimeInterval(Double(i-18)*60))
                snapshot.continuityKey="synthetic"
                if i==9 {history.breakContinuity(.codex)}
                history.record(snapshot,provider:.codex,now:snapshot.capturedAt);latest=snapshot
            }
            for dark in [false,true] {
                let view=FleetQuotaHistoryView(points:history.points,provider:.codex,snapshot:latest,now:now)
                    .padding(16).frame(width:PopoverChrome.width)
                    .background(dark ? Color(red:0.13,green:0.13,blue:0.14):Color(red:0.96,green:0.96,blue:0.97))
                    .environment(\.colorScheme,dark ? .dark:.light)
                let renderer=ImageRenderer(content:view);renderer.scale=2
                guard let image=renderer.cgImage,let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {return 1}
                try data.write(to:URL(fileURLWithPath:directory).appendingPathComponent("quota-history-\(dark ? "dark":"light").png"))
            }
            return 0
        } catch {return 1}
    }
}
