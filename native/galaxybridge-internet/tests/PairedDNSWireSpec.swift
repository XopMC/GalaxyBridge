import Foundation
@main struct PairedDNSWireSpec {
    static func main() {
        var query = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        precondition(PairedDNSWire.validQuery(query))
        precondition(!PairedDNSWire.validQuery(Data()))
        var response = query; response[2] |= 0x80
        precondition(!PairedDNSWire.validQuery(response))
        let framed = PairedDNSWire.frame(response)!
        precondition(PairedDNSWire.response(framed.prefix(1), for: query) == .incomplete)
        precondition(PairedDNSWire.response(framed.dropLast(), for: query) == .incomplete)
        precondition(PairedDNSWire.response(framed, for: query) == .complete(response))
        query[0] ^= 1
        precondition(PairedDNSWire.response(framed, for: query) == .invalid)
        precondition(PairedDNSWire.response(framed + Data([0]), for: query) == .invalid)
        precondition(PairedDNSWire.frame(Data(repeating: 0, count: 65_536)) == nil)
        print("Paired DNS wire framing PASS: fragmentation, bounds, query/response flags, transaction-ID fence and exact-one-message ownership")
    }
}
