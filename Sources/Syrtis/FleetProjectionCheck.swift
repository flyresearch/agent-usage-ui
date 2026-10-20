import Foundation
import SwiftUI
import AppKit
import UsageCore
import TokenBarCore

/// Synthetic checks call the same projection used by the original Syrtis views.
enum FleetProjectionCheck {
    static func run() async -> Int32 {
        do {
            guard AgentUsageMode.resolve(arguments:[],stored:nil,hasFleetConfiguration:false) == .native,
                  AgentUsageMode.resolve(arguments:[],stored:nil,hasFleetConfiguration:true) == .fleet,
                  AgentUsageMode.resolve(arguments:[],stored:"native",hasFleetConfiguration:true) == .native,
                  AgentUsageMode.resolve(arguments:["--fleet-offline"],stored:"native",hasFleetConfiguration:false) == .fleet,
                  AgentUsageMode.resolve(arguments:["--agent-usage-native"],stored:"fleet",hasFleetConfiguration:true) == .native,
                  BuildIdentity.shipping(arguments:[],bundleIdentifier:AgentUsageProduct.identifier,shortVersion:"1",buildNumber:"1",fleetMode:false) != nil,
                  BuildIdentity.shipping(arguments:["--fleet-projection-check"],bundleIdentifier:AgentUsageProduct.identifier,shortVersion:"1",buildNumber:"1",fleetMode:false) == nil,
                  BuildIdentity.shipping(arguments:[],bundleIdentifier:AgentUsageProduct.identifier,shortVersion:"1",buildNumber:"1",fleetMode:true) == nil,
                  UsageDataSources.make(arguments:["--demo"]) is DemoUsageDataSource
            else {throw FleetSourceError.unavailable}
            let updateKey=Data(repeating:1,count:32).base64EncodedString()
            guard UpdaterService.independentFeedAllowed(identifier:AgentUsageProduct.identifier,feed:"https://github.com/flyresearch/agent-usage-ui/releases/latest/download/appcast.xml",publicKey:updateKey),
                  !UpdaterService.independentFeedAllowed(identifier:AgentUsageProduct.identifier,feed:"https://github.com/Nanako0129/syrtis/raw/main/appcast.xml",publicKey:updateKey),
                  !UpdaterService.independentFeedAllowed(identifier:AgentUsageProduct.identifier,feed:"https://github.com/flyresearch/agent-usage-ui/releases/latest/download/appcast.xml",publicKey:nil)
            else {throw FleetSourceError.unavailable}
            try await MainActor.run {
            let migrationSuite="agent-usage-migration-check-"+UUID().uuidString
            let migrationDefaults=UserDefaults(suiteName:migrationSuite)!
            defer {migrationDefaults.removePersistentDomain(forName:migrationSuite)}
            migrationDefaults.set("hidden",forKey:TrayMode.storageKey)
            let migration=AgentUsagePreferencesMigration.plan(source:[TrayMode.storageKey:"today_tokens",PopoverChrome.heightKey:640,"credential":"synthetic-excluded"],existing:migrationDefaults.persistentDomain(forName:migrationSuite) ?? [:])
            guard migration.count==1,AgentUsagePreferencesMigration.apply(migration,defaults:migrationDefaults,domain:migrationSuite)==1,
                  migrationDefaults.string(forKey:TrayMode.storageKey)=="hidden",migrationDefaults.double(forKey:PopoverChrome.heightKey)==640 else {throw FleetSourceError.unavailable}
            migrationDefaults.set(700,forKey:PopoverChrome.heightKey)
            guard AgentUsagePreferencesMigration.undo(defaults:migrationDefaults,domain:migrationSuite)==0,migrationDefaults.double(forKey:PopoverChrome.heightKey)==700 else {throw FleetSourceError.unavailable}
            migrationDefaults.removeObject(forKey:PopoverChrome.heightKey)
            _=AgentUsagePreferencesMigration.apply(migration,defaults:migrationDefaults,domain:migrationSuite)
            guard AgentUsagePreferencesMigration.undo(defaults:migrationDefaults,domain:migrationSuite)==1,migrationDefaults.object(forKey:PopoverChrome.heightKey)==nil else {throw FleetSourceError.unavailable}
            }
            for locale in ["en","zh-Hans","zh-Hant"] {
                guard AppLanguage.localizedString("本机 · Syrtis 完整功能",locale:locale) != nil,
                      AppLanguage.localizedString("迁移旧额度历史",locale:locale) != nil else {throw FleetSourceError.unavailable}
            }
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
            // Production display policy: hiding must work without a live quota snapshot.
            guard FleetQuotaPolicy.visibleClients(client:nil,enabled:false,tabsHidden:"",limitsHidden:"",order:"").isEmpty,
                  FleetQuotaPolicy.visibleClients(client:nil,enabled:true,tabsHidden:"claude",limitsHidden:"agy",order:"")==["codex"],
                  FleetQuotaPolicy.visibleClients(client:"claude",enabled:true,tabsHidden:"",limitsHidden:"claude",order:"").isEmpty,
                  FleetQuotaPolicy.visibleClients(client:"workbuddy",enabled:true,tabsHidden:"",limitsHidden:"",order:"")==["workbuddy"],
                  FleetQuotaPolicy.visibleClients(client:nil,enabled:true,tabsHidden:"",limitsHidden:"",order:"claude,codex,agy")==["claude","codex","agy"]
            else {throw FleetSourceError.unavailable}
            let quota=try await checkNativeQuota(source)
            try await checkDesktop(graph:graph,quota:quota,fleet:fleet)
            try await FleetPresentationCheck.run(snapshot:snapshot,priced:priced,fleet:fleet)
            print("{\"passed\":60,\"failed\":[]}");return 0
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
            var points=history.points
            if CommandLine.arguments.contains("--stress-history") {
                let segment=UUID().uuidString
                let rows=(0..<10000).map { i -> [String:Any] in
                    ["id":UUID().uuidString,"provider":"codex","window":latest!.windows[0].id,
                     "title":"Synthetic full archive","time":now.timeIntervalSinceReferenceDate-Double(9999-i)*5,
                     "used":Double(i)*0.008,"reset":now.timeIntervalSinceReferenceDate+3600,
                     "duration":300,"segment":segment,"continuous":true]
                }
                points=try JSONDecoder().decode([QuotaObservation].self,from:JSONSerialization.data(withJSONObject:rows))
            }
            for dark in [false,true] {
                let view=FleetQuotaHistoryView(points:points,provider:.codex,snapshot:latest,now:now)
                    .padding(16).frame(width:PopoverChrome.width)
                    .background(dark ? Color(red:0.13,green:0.13,blue:0.14):Color(red:0.96,green:0.96,blue:0.97))
                    .environment(\.colorScheme,dark ? .dark:.light)
                let started=ProcessInfo.processInfo.systemUptime
                let renderer=ImageRenderer(content:view);renderer.scale=2
                guard let image=renderer.cgImage,let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {return 1}
                let elapsed=(ProcessInfo.processInfo.systemUptime-started)*1000
                print(String(format:"{\"history_render_points\":%d,\"dark\":%@,\"render_ms\":%.3f}",points.count,dark ? "true":"false",elapsed))
                try data.write(to:URL(fileURLWithPath:directory).appendingPathComponent("quota-history-\(dark ? "dark":"light").png"))
                let settings=FleetQuotaDisplaySettings().controls.padding(16).frame(width:PopoverChrome.width)
                    .background(dark ? Color(red:0.13,green:0.13,blue:0.14):Color(red:0.96,green:0.96,blue:0.97))
                    .environment(\.colorScheme,dark ? .dark:.light)
                let settingsRenderer=ImageRenderer(content:settings);settingsRenderer.scale=2
                guard let settingsImage=settingsRenderer.cgImage,
                      let settingsData=NSBitmapImageRep(cgImage:settingsImage).representation(using:.png,properties:[:]) else {return 1}
                try settingsData.write(to:URL(fileURLWithPath:directory).appendingPathComponent("quota-settings-\(dark ? "dark":"light").png"))
            }
            return 0
        } catch {return 1}
    }
}


extension FleetProjectionCheck {
    static func checkNativeQuota(_ source:FleetUsageDataSource) async throws -> AgentUsagePayload {
        let now=Date(timeIntervalSince1970:1767225600)
        func native(_ used:Double,_ minutes:Int?) throws -> NativeQuotaSnapshot {
            var row:[String:Any]=["usedPercent":used,"resetsAt":1767225660]
            if let minutes {row["windowDurationMins"]=minutes}
            return try CodexQuota.decodeLimits(JSONSerialization.data(withJSONObject:["rateLimits":["primary":row]]),now:now)
        }
        let codex=try native(50,300),claude=try native(70,10080)
        let payload=try await source.projectQuotas([(.codex,true,codex),(.claude,true,claude)],now:now)
        guard payload.agents[0].windows[0].durationSeconds==18000,
              payload.agents[0].windows[0].paceStatus.historyKey==nil else {throw FleetSourceError.unavailable}
        let current=FleetQuotaPolicy.current(payload,now:now)
        guard QuotaSelectionPolicy.resolveWindowLetter(payload:current,persistedSelection:QuotaResolver.auto,excluding:[])=="W",
              QuotaSelectionPolicy.resolveRemainingPercent(payload:current,persistedSelection:QuotaResolver.auto,excluding:[],cachedRemaining:nil)==30 else {throw FleetSourceError.unavailable}
        let explicit=QuotaResolver.selection(clientId:"codex",cardId:payload.agents[0].windows[0].cardId)
        guard QuotaSelectionPolicy.resolveWindowLetter(payload:current,persistedSelection:explicit,excluding:[])=="H" else {throw FleetSourceError.unavailable}
        for time in [now.addingTimeInterval(61),now.addingTimeInterval(91),now.addingTimeInterval(-6)] {
            guard FleetQuotaPolicy.current(payload,now:time)?.agents.isEmpty==true else {throw FleetSourceError.unavailable}
        }
        let aged=NativeQuotaSnapshot(capturedAt:now.addingTimeInterval(-60),windows:codex.windows)
        let mixed=try await source.projectQuotas([(.codex,true,aged),(.claude,true,claude)],now:now)
        let filtered=FleetQuotaPolicy.current(mixed,now:now.addingTimeInterval(31))
        guard filtered?.agents.count==1,filtered?.agents.first?.clientId=="claude",
              QuotaSelectionPolicy.resolveRemainingPercent(payload:filtered,persistedSelection:explicit,excluding:[],cachedRemaining:50)==nil else {throw FleetSourceError.unavailable}
        let unknown=try await source.projectQuotas([(.agy,true,native(20,nil))],now:now)
        guard QuotaSelectionPolicy.resolveWindowLetter(payload:unknown,persistedSelection:QuotaResolver.auto,excluding:[])==nil else {throw FleetSourceError.unavailable}
        return payload.replacingAgents(payload.agents+unknown.agents)
    }
}


extension FleetProjectionCheck {
    @MainActor static func checkDesktop(graph:UsagePayload,quota:AgentUsagePayload,fleet:FleetSnapshot) throws {
        for (code,expected) in [(3,AutostartService.Failure.invalidSignature),(4,.authorization),(6,.serviceMissing),(7,.serviceUnavailable),(11,.deniedByUser),(12,.alreadyRegistered),(99,.system)] {
            guard AutostartService.classify(domain:"SMAppServiceErrorDomain",code:code)==expected else {throw FleetSourceError.unavailable}
        }
        guard AutostartService.classify(domain:"synthetic-untrusted-domain",code:3) == .system else {throw FleetSourceError.unavailable}
        let state=FleetUIState();state.fleet=fleet
        guard state.allClients==["codex","hermes"] else {throw FleetSourceError.unavailable}
        guard AutostartService.supports(bundleURL:URL(fileURLWithPath:"/synthetic/Agent Usage.app"),identifier:"org.example.fixture"),
              !AutostartService.supports(bundleURL:URL(fileURLWithPath:"/synthetic/cli"),identifier:"org.example.fixture"),
              !AutostartService.supports(bundleURL:URL(fileURLWithPath:"/synthetic/App.app"),identifier:nil) else {throw FleetSourceError.unavailable}
        let suite="agentusage-language-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        AppLanguage.simplifiedChinese.apply(to:defaults)
        guard defaults.stringArray(forKey:"AppleLanguages")==["zh-Hans"] else {throw FleetSourceError.unavailable}
        AppLanguage.system.apply(to:defaults)
        guard defaults.persistentDomain(forName:suite)?["AppleLanguages"]==nil else {throw FleetSourceError.unavailable}
        let official=AgentIconView.availableOfficialClientIDs()
        let rows=ClientTray.settingsRows(presentClients:["codex","claude","agy"],payload:quota,enabled:[],selections:[:],hidden:[],orderRaw:"",officialClients:official)
        guard Set(rows.map(\.clientId))==Set(["codex","claude","agy"]) else {throw FleetSourceError.unavailable}
        let selection=quota.agents.first{$0.clientId=="codex"}!.windows[0].cardId
        let items=ClientTray.runtimePresentations(graph:graph,payload:quota,enabled:["codex"],selections:["codex":selection],hidden:[],officialClients:official)
        guard items.count==1,items[0].clientId=="codex",items[0].remainingPercent==50 else {throw FleetSourceError.unavailable}
        let hidden=ClientTray.runtimePresentations(graph:graph,payload:quota,enabled:["codex"],selections:[:],hidden:["codex"],officialClients:official)
        guard hidden.isEmpty else {throw FleetSourceError.unavailable}
        let offline=ClientTray.runtimePresentations(graph:graph,payload:nil,enabled:["codex"],selections:["codex":selection],hidden:[],officialClients:official,missingSnapshotIsTransient:true)
        guard offline.count==1,offline[0].remainingPercent==nil,offline[0].status == .unavailable else {throw FleetSourceError.unavailable}
    }
    @MainActor static func desktopReadback() async -> Int32 {
        _ = NSApplication.shared
        let state=await AutostartService.readState()
        var result=AutostartService.diagnostic()
        result["bundle_available"]=AutostartService.isAvailable
        result["login_startup_state"]=String(describing:state)
        result["fleet_mode"]=FleetMode.enabled
        guard let data=try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys),let text=String(data:data,encoding:.utf8) else {return 1}
        print(text);return 0
    }
}
