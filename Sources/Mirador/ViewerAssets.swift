import Foundation

public struct StaticAsset: Equatable {
    public let data: Data
    public let contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}

public struct ViewerAssets: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static var `default`: ViewerAssets {
        if let override = ProcessInfo.processInfo.environment["MIRADOR_WEB_ROOT"], !override.isEmpty {
            return ViewerAssets(rootDirectory: URL(fileURLWithPath: override, isDirectory: true))
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath)
        let executableDirectory = executable.deletingLastPathComponent()
        let repoFromInstalledBinary = executableDirectory.deletingLastPathComponent().appendingPathComponent("web", isDirectory: true)
        if FileManager.default.fileExists(atPath: repoFromInstalledBinary.appendingPathComponent("viewer.html").path) {
            return ViewerAssets(rootDirectory: repoFromInstalledBinary)
        }

        let repoFromWorkingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("web", isDirectory: true)
        return ViewerAssets(rootDirectory: repoFromWorkingDirectory)
    }

    public func renderHTML(authToken: String) -> String? {
        let url = rootDirectory.appendingPathComponent("viewer.html")
        guard let template = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return template
            .replacingOccurrences(of: "{{AUTH_TOKEN_QUERY}}", with: Self.queryEscape(authToken))
            .replacingOccurrences(of: "{{AUTH_TOKEN_JS}}", with: Self.javascriptSingleQuotedEscape(authToken))
    }

    public func staticAsset(for requestPath: String) -> StaticAsset? {
        guard let filename = Self.allowedAssetFilenames[requestPath] else {
            return nil
        }
        let url = rootDirectory.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return StaticAsset(data: data, contentType: Self.contentType(for: filename))
    }

    private static let allowedAssetFilenames: [String: String] = [
        "/assets/viewer.css": "viewer.css",
        "/assets/viewer.js": "viewer.js"
    ]

    private static func contentType(for filename: String) -> String {
        if filename.hasSuffix(".css") {
            return "text/css; charset=utf-8"
        }
        if filename.hasSuffix(".js") {
            return "application/javascript; charset=utf-8"
        }
        return "application/octet-stream"
    }

    private static func queryEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/#%'")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func javascriptSingleQuotedEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
    }
}

public enum ViewerHTML {
    public static func render(host: String, port: Int, authToken: String = "") -> String {
        if let html = ViewerAssets.default.renderHTML(authToken: authToken) {
            return html
        }

        let escapedToken = authToken
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
          <title>mirador viewer</title>
          <style>html, body { margin: 0; background: #020617; color: #e2e8f0; font-family: sans-serif; }</style>
        </head>
        <body>
          <h1>mirador viewer</h1>
          <p>Viewer assets were not found on disk. Set <code>MIRADOR_WEB_ROOT</code> or install the repository <code>web/</code> directory beside <code>bin/</code>.</p>
          <p><a href="/metrics?token=\(escapedToken)">metrics</a> · <a href="/stream.mjpg?token=\(escapedToken)">stream</a> · <code>/input</code></p>
          <div id="input-overlay" tabindex="0"></div>
        </body>
        </html>
        """
    }
}
