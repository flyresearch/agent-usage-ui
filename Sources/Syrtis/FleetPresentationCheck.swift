import Foundation
import UsageCore
import TokenBarCore

enum FleetPresentationCheck {
    static func run(snapshot:UsageSnapshot,priced:UsageSnapshot,fleet:FleetSnapshot) async throws {
        let worker=FleetPresentation()
        let now=Date(timeIntervalSince1970:1767225600)
        let today=try await worker.menu(.local(snapshot),mode:.todayTokens,now:now)
        let all=try await worker.menu(.local(snapshot),mode:.totalTokens,now:now)
        let nextDay=try await worker.menu(.local(snapshot),mode:.todayTokens,now:now.addingTimeInterval(86400))
        guard today.title=="100",all.title=="107",nextDay.title=="0" else {throw FleetSourceError.unavailable}
        let unknown=try await worker.menu(.local(snapshot),mode:.todayCost,now:now)
        guard unknown.title=="金额 —" else {throw FleetSourceError.unavailable}
        let ids=await worker.clients(.local(snapshot))
        guard ids==["codex","hermes"] else {throw FleetSourceError.unavailable}
        let graph=try await FleetUsageDataSource().projectGraph(.local(snapshot),year:nil)
        let old=ClientTray.runtimePresentations(graph:graph,payload:nil,enabled:["codex"],selections:[:],hidden:[],officialClients:["codex"])
        let new=ClientTray.runtimePresentations(clients:ids,payload:nil,enabled:["codex"],selections:[:],hidden:[],officialClients:["codex"])
        guard old==new else {throw FleetSourceError.unavailable}
        let first=await worker.header(fleet:nil,local:priced,host:"",clients:["codex"],year:nil)
        let repeated=await worker.header(fleet:nil,local:priced,host:"",clients:["codex"],year:nil)
        guard first==repeated,first.unallocated==7,first.note.contains("3") else {throw FleetSourceError.unavailable}
#if DEBUG
        guard await worker.headerBuildCount==1 else {throw FleetSourceError.unavailable}
#endif
        var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(priced)) as! [String:Any]
        var rows=value["rows"] as! [[String:Any]]
        rows[0]["messages"]=["known":999,"complete":true];value["rows"]=rows
        // Same timestamp and row identity, changed content: cannot reuse the old note.
        let corrected=try UsageSnapshot.decode(JSONSerialization.data(withJSONObject:value))
        let changed=await worker.header(fleet:nil,local:corrected,host:"",clients:["codex"],year:nil)
        guard changed != first,changed.note.contains("999") else {throw FleetSourceError.unavailable}
#if DEBUG
        guard await worker.headerBuildCount==2 else {throw FleetSourceError.unavailable}
#endif
        let otherYear=await worker.header(fleet:nil,local:corrected,host:"",clients:["codex"],year:"2025")
        let otherAgent=await worker.header(fleet:nil,local:corrected,host:"",clients:["hermes"],year:nil)
        let missing=await worker.header(fleet:fleet,local:nil,host:"absent",clients:["codex"],year:nil)
        guard otherYear != changed,otherAgent != changed,missing.note=="尚无当前配置的可用用量" else {throw FleetSourceError.unavailable}
        let invalidated=await worker.header(fleet:nil,local:nil,host:"",clients:["codex"],year:nil)
        guard invalidated.note=="尚无当前配置的可用用量" else {throw FleetSourceError.unavailable}

        if ProcessInfo.processInfo.environment["AGENT_USAGE_PRESENTATION_BENCHMARK"]=="1" {
            let n=10000
            value["rows"]=Array(repeating:rows[0],count:n)
            value["totals"]=["input":10*n,"cache_read":90*n,"cache_write":0,"output":0,"reasoning":0]
            let largeData=try JSONSerialization.data(withJSONObject:value)
            let large=try UsageSnapshot.decode(largeData)
            var menuTimes=[Double](),headerTimes=[Double](),clientTimes=[Double]()
            _=await worker.header(fleet:nil,local:large,host:"",clients:["codex"],year:nil)
            for _ in 0..<5 {
                // Re-decoded equivalent data avoids the Array storage-identity fast path.
                let refreshed=try UsageSnapshot.decode(largeData)
                var started=ProcessInfo.processInfo.systemUptime
                _=try await worker.menu(.local(large),mode:.todayCost,now:now)
                menuTimes.append((ProcessInfo.processInfo.systemUptime-started)*1000)
                started=ProcessInfo.processInfo.systemUptime
                _=await worker.header(fleet:nil,local:refreshed,host:"",clients:["codex"],year:nil)
                headerTimes.append((ProcessInfo.processInfo.systemUptime-started)*1000)
                started=ProcessInfo.processInfo.systemUptime
                _=await worker.clients(.local(large))
                clientTimes.append((ProcessInfo.processInfo.systemUptime-started)*1000)
            }
            print(String(format:"{\"rows\":10000,\"menu_median_ms\":%.3f,\"cached_header_median_ms\":%.3f,\"client_ids_median_ms\":%.3f}",menuTimes.sorted()[2],headerTimes.sorted()[2],clientTimes.sorted()[2]))
        }
    }
}
