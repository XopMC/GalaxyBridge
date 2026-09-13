import CryptoKit
import Foundation

// Fixture-only executable. The separately hashed immutable factory is compiled
// beside this entrypoint, never copied or changed. No consumer or product path.
@main
enum ExportStockFixture {
  static func main() throws {
    guard CommandLine.arguments.count == 3,
      CommandLine.arguments[1] == "--output",
      CommandLine.arguments[2].hasPrefix("/")
    else { throw QuicFixtureError.malformed }
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw QuicFixtureError.malformed }
    var total = 0
    func save(_ records: [Data], name: String) throws {
      guard !records.isEmpty, records.count <= 256 else { throw QuicFixtureError.capacity }
      var output = Data()
      for record in records {
        guard !record.isEmpty, record.count <= 4 * 1024 * 1024 + 12,
          output.count + 4 + record.count <= 16 * 1024 * 1024
        else { throw QuicFixtureError.capacity }
        var length = UInt32(record.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(record)
      }
      total += output.count
      guard total <= 16 * 1024 * 1024 else { throw QuicFixtureError.capacity }
      try output.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
      let digest = SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
      try (digest + "\n").write(to: directory.appendingPathComponent(name + ".sha256"), atomically: true, encoding: .utf8)
      print("fixture=\(name) records=\(records.count) bytes=\(output.count) sha256=\(digest)")
    }
    for hevc in [false, true] {
      let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
      try save(
        QuicCodecFixtureFactory.stockVideo(fixture), name: hevc ? "hevc.stock" : "h264.stock")
    }
    let audio = try QuicCodecFixtureFactory.audio()
    var records = [
      Data([0, 97, 97, 99]),
      QuicCodecFixtureFactory.stockPacket(audio.configuration, pts: 0, flags: 1 << 62),
    ]
    records.append(
      contentsOf: audio.packets.map {
        QuicCodecFixtureFactory.stockPacket($0.bytes, pts: $0.pts, flags: 0)
      })
    try save(records, name: "aac.stock")
  }
}
