import Foundation

@main
enum ADBCommandRunnerSpec {
    static func main() throws {
        let runner = ADBCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        // Both pipes exceed kernel capacity. Waiting for exit before draining deadlocks.
        let flooded = try runner.run(arguments: ["-c", "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2"], timeout: 3)
        precondition(flooded.stdout.count == 262144 && flooded.stderr.count == 262144)
        let input = try runner.run(arguments: ["-c", "read code; printf '%s' \"$code\""], input: Data("123456\n".utf8), timeout: 2)
        precondition(input.stdout == Data("123456".utf8))
        let failed = try runner.run(arguments: ["-c", "printf 'failure' >&2; exit 17"], timeout: 2)
        precondition(failed.exitCode == 17 && failed.stderr == Data("failure".utf8))
        do {
            _ = try runner.run(arguments: ["-c", "head -c 262144 /dev/zero"], timeout: 2, outputLimit: 65536)
            preconditionFailure("Oversized output must not appear as a successful partial response")
        } catch ADBCommandRunner.Failure.outputLimitExceeded { }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try runner.run(arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
            preconditionFailure("A hung command must have a deadline")
        } catch ADBCommandRunner.Failure.timedOut { }
        precondition(ProcessInfo.processInfo.systemUptime - start < 1.5)
        // A descendant inheriting the pipe must not keep a finished command waiting for EOF.
        let inherited = try runner.run(arguments: ["-c", "sleep 1 & printf 'done'"], timeout: 0.2)
        precondition(inherited.stdout == Data("done".utf8))
        print("ADB command runner: flood, separate stderr, stdin, exit status, output cap, TERM-resistant timeout and inherited-pipe checks passed")
    }
}
