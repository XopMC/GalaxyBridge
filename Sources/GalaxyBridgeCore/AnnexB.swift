import Foundation

public enum AnnexB {
    public static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }
        var starts: [(codeStart: Int, payloadStart: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1
            {
                starts.append((index, index + 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { return [data] }
        return starts.enumerated().compactMap { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1].codeStart : bytes.count
            guard start.payloadStart < end else { return nil }
            return Data(bytes[start.payloadStart ..< end])
        }
    }

    public static func lengthPrefixedSample(from data: Data) -> Data {
        var result = Data()
        for unit in nalUnits(in: data) {
            guard unit.count <= Int(UInt32.max) else { continue }
            var length = UInt32(unit.count).bigEndian
            Swift.withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(unit)
        }
        return result
    }
}
