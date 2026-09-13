#!/usr/bin/env swift
import Foundation

// Compatibility entry point. Both platforms always use the same artwork.
let generator = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("generate-app-icons.swift")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [generator.path] + Array(CommandLine.arguments.dropFirst())
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
