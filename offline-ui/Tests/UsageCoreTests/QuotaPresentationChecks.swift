import Foundation
import UsageCore

func quotaPresentationChecks(_ check:(String,() throws -> Void)->Void) {
    let now=Date(timeIntervalSince1970:1767225600)
    func key(_ index:Int) -> String {"bucket-"+String(repeating:String(index),count:64)+"-primary"}
    func fixture(_ count:Int,windows:Int) throws -> [QuotaObservation] {
        let segment=UUID().uuidString
        let rows=(0..<count).map { i -> [String:Any] in
            ["id":UUID().uuidString,"provider":"codex","window":key(i%windows),
             "title":"Fixture \(i%windows)","time":now.timeIntervalSinceReferenceDate-Double(count-1-i)*5,
             "used":Double(i)/Double(count)*80,"reset":now.timeIntervalSinceReferenceDate+3600,
             "duration":300,"segment":segment,"continuous":true]
        }
        return try JSONDecoder().decode([QuotaObservation].self,from:JSONSerialization.data(withJSONObject:rows))
    }
    check("history_presentation_full_archive_filters_and_preserves_chart_semantics") {
        let points=try fixture(10000,windows:5)
        let report=QuotaHistoryPresentation(points:points,selectedWindow:key(1),days:1,now:now)
        let expected=points.filter{$0.window==key(1)}
        try require(report.visible==expected && report.windowIDs.count==5 && report.titles[key(1)]=="Fixture 1")
        try require(report.plotted.count<=721 && report.plotted.first==expected.first && report.plotted.last==expected.last)
        let fallback=QuotaHistoryPresentation(points:points,selectedWindow:"missing",days:7,now:now)
        try require(fallback.selectedWindow==key(4) && fallback.visible==points.filter{$0.window==key(4)})
        let later=QuotaHistoryPresentation(points:points,selectedWindow:key(1),days:1,now:now.addingTimeInterval(86401))
        try require(later.visible.isEmpty && later.plotted.isEmpty && later.trend==nil)
        var changed=points[0];changed.used+=1
        try require(changed != points[0])
    }
    check("history_presentation_trend_uses_all_samples_and_preserves_boundaries") {
        var points=try fixture(2000,windows:1)
        points[1000].segment=UUID().uuidString
        let report=QuotaHistoryPresentation(points:points,selectedWindow:key(0),days:1,now:now)
        let expected=NativeQuotaHistory.trend(points,now:now)
        try require(report.trend?.sampleCount==expected?.sampleCount && report.trend?.percentagePointsPerHour==expected?.percentagePointsPerHour)
        try require(report.visible.count==2000 && report.plotted.count<report.visible.count)
        let empty=QuotaHistoryPresentation(points:[],selectedWindow:"missing",days:1,now:now)
        try require(empty.windowIDs.isEmpty && empty.selectedWindow.isEmpty && empty.visible.isEmpty)
    }
    if ProcessInfo.processInfo.environment["AGENT_USAGE_HISTORY_BENCHMARK"]=="1" {
        check("history_presentation_bounded_latency") {
            let points=try fixture(10000,windows:5)
            var times=[Double]()
            for _ in 0..<20 {
                let start=ProcessInfo.processInfo.systemUptime
                let report=QuotaHistoryPresentation(points:points,selectedWindow:key(1),days:1,now:now)
                try require(report.visible.count==2000)
                times.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            }
            times.sort()
            print(String(format:"{\"history_projection_points\":10000,\"iterations\":20,\"median_ms\":%.3f,\"p95_ms\":%.3f}",times[10],times[18]))
            try require(times[18]<100)
            // Exact old getter dependency reproduced on a smaller bounded input,
            // not a timing oracle for parser correctness or end-to-end UI latency.
            let small=Array(points.prefix(1000))
            let selection=key(1)
            func legacyWindow() -> String {Array(Set(small.map(\.window))).sorted().contains(selection) ? selection:small.last?.window ?? ""}
            let oldStart=ProcessInfo.processInfo.systemUptime
            let old=small.filter{$0.window==legacyWindow() && $0.time>=now.addingTimeInterval(-86400) && $0.time<=now}
            let oldMs=(ProcessInfo.processInfo.systemUptime-oldStart)*1000
            let newStart=ProcessInfo.processInfo.systemUptime
            let new=QuotaHistoryPresentation(points:small,selectedWindow:key(1),days:1,now:now)
            let newMs=(ProcessInfo.processInfo.systemUptime-newStart)*1000
            try require(old==new.visible)
            print(String(format:"{\"comparison_points\":1000,\"old_filter_ms\":%.3f,\"new_full_projection_ms\":%.3f,\"visible_equal\":true}",oldMs,newMs))
        }
    }
}
