import AppKit
import ChronatoCore

// One binary, three jobs:
//   Chronato              menu-bar app
//   Chronato mcp          MCP server for an allow-listed AI agent (stdio)
//   Chronato snapshot D   render the UI with fixture data to PNGs in D (dev aid)
//   Chronato selftest …   end-to-end checks against scripts/mock-kimai.py (dev aid, scripts/e2e.sh)
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "mcp":
    Task { exit(await MCPServer().run()) }
    dispatchMain()
case "snapshot":
    MainActor.assumeIsolated { Snapshot.run(Array(arguments.dropFirst())) }
case "selftest":
    Task { @MainActor in exit(await SelfTest.run(Array(arguments.dropFirst()))) }
    dispatchMain()
case "--version", "version":
    print(AppInfo.version)
default:
    // Builds before KimaiClient.defaultSession cached Kimai's answers, with the token, in
    // ~/Library/Caches/<bundle id>/Cache.db. Nothing writes there any more; clear it.
    URLCache.shared.removeAllCachedResponses()
    MainActor.assumeIsolated { ChronatoApp.main() }
}
