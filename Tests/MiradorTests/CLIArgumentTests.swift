import Testing
@testable import Mirador

@Test func parsesDefaultCLIArguments() throws {
    let options = try MiradorMain.parseArguments([])

    #expect(options == MiradorMain.Options(host: "127.0.0.1", port: 8787))
}

@Test func parsesHostAndPortCLIArguments() throws {
    let options = try MiradorMain.parseArguments(["--host", "0.0.0.0", "--port", "5900"])

    #expect(options == MiradorMain.Options(host: "0.0.0.0", port: 5900))
}

@Test func rejectsUnknownUserCLIArguments() {
    do {
        _ = try MiradorMain.parseArguments(["--test-bundle-path", "/tmp/MiradorTests.xctest"])
        Issue.record("Expected --test-bundle-path to remain invalid for direct CLI parsing")
    } catch let error as MiradorMain.CLIError {
        #expect(error == .unknownArgument("--test-bundle-path"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func detectsSwiftPMTestRunnerArguments() {
    #expect(MiradorMain.isSwiftPMTestRunnerInvocation(
        commandName: "/tmp/MiradorPackageTests.xctest/Contents/MacOS/MiradorPackageTests",
        arguments: ["--test-bundle-path", "/tmp/MiradorTests.xctest"]
    ))
    #expect(!MiradorMain.isSwiftPMTestRunnerInvocation(commandName: "/tmp/mirador", arguments: ["--test-bundle-path", "/tmp/MiradorTests.xctest"]))
    #expect(!MiradorMain.isSwiftPMTestRunnerInvocation(commandName: "/tmp/MiradorPackageTests", arguments: ["--host", "127.0.0.1"]))
}

@Test func authTokenResolutionNeverFallsBackToEmptyToken() throws {
    #expect(MiradorMain.resolveAuthToken(environment: ["MIRADOR_TOKEN": "configured"]) == "configured")
    #expect(!MiradorMain.resolveAuthToken(environment: [:]).isEmpty)
}
