import Foundation
import os

/// What `warn` prefixes its messages with. Each executable sets it once at startup.
public nonisolated(unsafe) var programName = "dock2"

/// Where `note` and `warn` also write, when set. Opened as an app, stdout and stderr go nowhere, and
/// this is what `log show --predicate 'subsystem == "zip.tanner.dock2"'` reads back afterwards.
public nonisolated(unsafe) var systemLog: Logger?

public func note(_ message: String) {
    print(message)
    fflush(stdout)
    systemLog?.notice("\(message, privacy: .public)")
}

public func warn(_ message: String) {
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
    systemLog?.error("\(message, privacy: .public)")
}
