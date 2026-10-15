import Foundation

public struct MessageCount:Codable,Equatable,Sendable {
    public let known:UInt64
    public let complete:Bool
    public init(known:UInt64=0,complete:Bool=false) {self.known=known;self.complete=complete}
    public func adding(_ other:Self) throws -> Self {
        let (n,overflow)=known.addingReportingOverflow(other.known);guard !overflow else {throw UsageError.overflow}
        return Self(known:n,complete:complete && other.complete)
    }
    public static func total(_ rows:[UsageRow]) throws -> Self {
        try rows.reduce(Self(known:0,complete:true)) {try $0.adding($1.messages ?? Self())}
    }
}
public struct PriceCatalog:Decodable,Sendable {
    public struct Rate:Decodable,Sendable {
        public let input:String
        public let cache_read:String
        public let cache_write:String?
        public let output:String
        public let reasoning:String
        public let source:String
        var values:[String?] {[input,cache_read,cache_write,output,reasoning]}
    }
    public let schema_version:Int
    public let version:String
    public let currency:String
    public let basis:String
    public let rates:[String:Rate]
    public static func decode(_ data:Data) throws -> Self {
        let c=try JSONDecoder().decode(Self.self,from:data)
        guard c.schema_version==1,c.currency=="USD",label(c.version),c.basis=="current-list-short-context-5m-cache-peak",!c.rates.isEmpty else {throw UsageError.invalidSnapshot}
        for (key,rate) in c.rates {
            guard label(key),URL(string:rate.source)?.scheme=="https" else {throw UsageError.invalidSnapshot}
            for text in rate.values.compactMap({$0}) {
                guard text.range(of:"^[0-9]+(\\.[0-9]{1,9})?$",options:.regularExpression) != nil,let n=Decimal(string:text,locale:Locale(identifier:"en_US_POSIX")),n>=0,n<=1_000_000 else {throw UsageError.invalidSnapshot}
            }
        }
        return c
    }
    public static func bundled() throws -> Self {
        guard let url=Bundle.module.url(forResource:"prices-v1",withExtension:"json",subdirectory:"Resources") else {throw UsageError.invalidSnapshot}
        return try decode(Data(contentsOf:url))
    }
    public func estimate(_ row:UsageRow) throws -> Decimal? {
        let total=try row.tokens.total
        guard let rate=rates[row.model] else {return total==0 ? Decimal.zero:nil}
        let counts=[row.tokens.input,row.tokens.cache_read,row.tokens.cache_write,row.tokens.output,row.tokens.reasoning]
        var result=Decimal.zero
        for (count,text) in zip(counts,rate.values) where count>0 {
            guard let text,let price=Decimal(string:text,locale:Locale(identifier:"en_US_POSIX")),let n=Decimal(string:String(count)) else {return nil}
            result += n*price/1_000_000
        }
        guard !result.isNaN else {throw UsageError.overflow}
        return result
    }
    public func summary(_ rows:[UsageRow]) throws -> CostEstimate {
        var sum=Decimal.zero;var priced:UInt64=0;var total:UInt64=0;var any=false;var complete=true
        for row in rows {
            let tokens=try row.tokens.total
            let (next,overflow)=total.addingReportingOverflow(tokens);guard !overflow else {throw UsageError.overflow};total=next
            if let value=try estimate(row) {sum+=value;priced+=tokens;any=true} else {complete=false}
        }
        return CostEstimate(usd:any || rows.isEmpty ? sum:nil,pricedTokens:priced,totalTokens:total,complete:complete,version:version)
    }
}
public struct CostEstimate:Sendable {
    public let usd:Decimal?
    public let pricedTokens:UInt64
    public let totalTokens:UInt64
    public let complete:Bool
    public let version:String
    public var doubleValue:Double? {usd.map{NSDecimalNumber(decimal:$0).doubleValue}}
}
