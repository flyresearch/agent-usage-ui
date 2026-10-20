import Foundation

/// One projection per view update. Never resolve the selected window inside
/// the per-observation predicate: that turns a bounded archive into O(n²) work.
public struct QuotaHistoryPresentation: Sendable {
    public let windowIDs:[String]
    public let titles:[String:String]
    public let selectedWindow:String
    public let visible:[QuotaObservation]
    public let plotted:[QuotaObservation]
    public let trend:QuotaTrend?

    public init(points:[QuotaObservation],selectedWindow:String,days:Int,now:Date) {
        var labels=[String:String]()
        for point in points {labels[point.window]=point.title}
        titles=labels
        windowIDs=labels.keys.sorted()
        let selected=labels[selectedWindow] != nil ? selectedWindow:points.last?.window ?? ""
        self.selectedWindow=selected
        let start=now.addingTimeInterval(-Double(days)*86400)
        let filtered=points.filter{$0.window==selected && $0.time>=start && $0.time<=now}
        visible=filtered
        let step=max(1,Int(ceil(Double(filtered.count)/720)))
        var samples=stride(from:0,to:filtered.count,by:step).map{filtered[$0]}
        if let last=filtered.last,samples.last?.id != last.id {samples.append(last)}
        plotted=samples
        trend=NativeQuotaHistory.trend(filtered,now:now)
    }
}
