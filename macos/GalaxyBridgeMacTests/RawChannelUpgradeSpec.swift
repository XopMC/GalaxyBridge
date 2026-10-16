import Foundation
@main struct RawChannelUpgradeSpec {
 static func main() throws {
  func frame(_ b:Data)->Data { var n=UInt32(b.count).bigEndian;return withUnsafeBytes(of:&n){Data($0)}+b }
  let hello=Data([1,2]),ready=Data([3]),raw=Data([0,0,0,0,0,0,0,1,0xff])
  var d=RawChannelUpgradeDecoder()
  try d.append(frame(hello)+frame(ready)+raw)
  let h=try d.nextFrame(),r=try d.nextFrame();precondition(h==hello&&r==ready)
  precondition(d.takeRawRemainder()==raw,"raw capture bytes coalesced with readiness must never be parsed as control")
  var f=RawChannelUpgradeDecoder()
  for byte in frame(hello) {try f.append(Data([byte]))}
  let p=try f.nextFrame();precondition(p==hello)
  var bad=RawChannelUpgradeDecoder()
  try bad.append(Data([0xff,0xff,0xff,0xff]))
  do {_=try bad.nextFrame();fatalError("unbounded frame")}catch{}
  print("PASS exact control-to-raw upgrade with coalesced producer header and fragmented frames")
 }
}
