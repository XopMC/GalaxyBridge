import CryptoKit
import Foundation

public struct TransferManifest: Equatable, Sendable {
    public let transferID: UUID
    public let relativeName: String
    public let size: UInt64
    public let mimeType: String
    public let sha256: Data

    public init(
        transferID: UUID,
        relativeName: String,
        size: UInt64,
        mimeType: String,
        sha256: Data
    ) {
        self.transferID = transferID
        self.relativeName = relativeName
        self.size = size
        self.mimeType = mimeType
        self.sha256 = sha256
    }
}

public enum TransferAssemblerError: Error, Equatable {
    case invalidRelativeName(String)
    case unexpectedOffset(expected: UInt64, actual: UInt64)
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case checksumMismatch
}

public struct TransferAssembler {
    public let manifest: TransferManifest
    public private(set) var confirmedOffset: UInt64

    private let partURL: URL
    private let finalURL: URL

    public init(manifest: TransferManifest, destinationDirectory: URL) throws {
        guard Self.isSafeRelativeName(manifest.relativeName) else {
            throw TransferAssemblerError.invalidRelativeName(manifest.relativeName)
        }
        self.manifest = manifest
        partURL = destinationDirectory.appendingPathComponent(manifest.relativeName + ".part")
        finalURL = destinationDirectory.appendingPathComponent(manifest.relativeName)

        if !FileManager.default.fileExists(atPath: partURL.path) {
            guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let readHandle = try FileHandle(forReadingFrom: partURL)
        defer { try? readHandle.close() }
        confirmedOffset = try readHandle.seekToEnd()
    }

    public mutating func append(_ content: Data, at offset: UInt64) throws {
        guard offset == confirmedOffset else {
            throw TransferAssemblerError.unexpectedOffset(
                expected: confirmedOffset,
                actual: offset
            )
        }

        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: content)
        confirmedOffset += UInt64(content.count)
    }

    public func finalize() throws -> URL {
        guard confirmedOffset == manifest.size else {
            throw TransferAssemblerError.sizeMismatch(
                expected: manifest.size,
                actual: confirmedOffset
            )
        }

        let content = try Data(contentsOf: partURL, options: .mappedIfSafe)
        guard Data(SHA256.hash(data: content)) == manifest.sha256 else {
            throw TransferAssemblerError.checksumMismatch
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        return finalURL
    }

    private static func isSafeRelativeName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("\0")
    }
}
