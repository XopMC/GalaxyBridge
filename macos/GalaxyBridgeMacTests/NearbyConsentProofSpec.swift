import Foundation
import CryptoKit

@main enum NearbyConsentProofSpec {
    static func main() throws {
        precondition(NearbyConsentProof.comparison(Data("mac".utf8),Data("phone".utf8),Data("request".utf8)) == "203337")
        let vector = NearbyConsentProof.context(token:Data(repeating:7,count:32),identity:Data(repeating:4,count:65),name:"Mac")
        precondition(vector.map { String(format:"%02x",$0) }.joined() == "4742436f6e7330313990a734dc6ff958d7e887d0b51ef5359dcd13ed5e8b1ec6")
        let token = Data(repeating: 7,count:32), key = P256.Signing.PrivateKey()
        let context = NearbyConsentProof.context(token:token,identity:key.publicKey.x963Representation,name:"Mac")
        precondition(context.count == 32 && context.prefix(8) == Data("GBCons01".utf8))
        precondition(context != NearbyConsentProof.context(token:Data(repeating:8,count:32),identity:key.publicKey.x963Representation,name:"Mac"))
        precondition(context != NearbyConsentProof.context(token:token,identity:key.publicKey.x963Representation,name:"Other"))
        let a = NearbyBootstrapAgreement(role:.initiator,deviceID:"Mac",context:context,identity:key.publicKey.x963Representation,sign:{try key.signature(for:$0).derRepresentation})
        let other = P256.Signing.PrivateKey()
        let b = NearbyBootstrapAgreement(role:.responder,deviceID:"Phone",context:context,identity:other.publicKey.x963Representation,sign:{try other.signature(for:$0).derRepresentation})
        let ah = try a.hello(), bh = try b.hello()
        var initiator = try a.complete(remote:bh,expectedIdentity:bh.identity)
        var responder = try b.complete(remote:ah,expectedIdentity:ah.identity)
        let proof = NearbyConsentProof.comparison(ah.transcript,bh.transcript,token)
        let encrypted = try initiator.seal(token)
        let opened = try responder.open(encrypted)
        precondition(opened == token)
        precondition(proof != NearbyConsentProof.comparison(bh.transcript,ah.transcript,token))
        precondition(proof != NearbyConsentProof.comparison(ah.transcript,bh.transcript,Data(repeating:8,count:32)))
        print("PASS committed consent comparison, transcript direction and encrypted secret")
    }
}
