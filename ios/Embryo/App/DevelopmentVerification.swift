#if DEBUG
import Foundation

/// Device-readable connection evidence for an explicitly provisioned development build.
/// This helper never reads the Keychain or copies credentials into its output.
enum DevelopmentVerification {
    static func writeConnection(connected: Bool, hasToken: Bool, models: [String], imageCount: Int, error: String?, diagnostic: String? = nil) {
        struct Report: Encodable {
            let timestamp: String
            let connected: Bool
            let hasToken: Bool
            let models: [String]
            let imageCount: Int
            let error: String?
            let diagnostic: String?
            let bootstrapFileExists: Bool
        }

        let manager = FileManager.default
        guard let directory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let path = directory.appendingPathComponent("connection-verification.json")
        let bootstrap = directory.appendingPathComponent("connection-bootstrap.json")
        let report = Report(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            connected: connected,
            hasToken: hasToken,
            models: models,
            imageCount: imageCount,
            // Caller error messages are not persisted: they may grow to include request details.
            error: error == nil ? nil : "Connection check failed; see the message in the app.",
            diagnostic: diagnostic,
            bootstrapFileExists: manager.fileExists(atPath: bootstrap.path)
        )
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: path, options: [.atomic, .completeFileProtection])
            var excludedPath = path
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excludedPath.setResourceValues(values)
        } catch {
            // Diagnostic writes must not block connection setup or leak request details to logs.
        }
    }
}
#endif
