// TipTour/Hermes/HermesRuntimeVersion.swift
//
// Reads the version manifest emitted by BuildScripts/bundle-hermes.sh.
// Format: one "key=value" per line, ASCII only. All five fields required.

import Foundation

struct HermesRuntimeVersion: Equatable {
    let hermesGitRef: String
    let hermesVersion: String
    let pythonVersion: String
    let pythonBuild: String
    let bundledAt: String

    enum ReadError: Error, Equatable, CustomStringConvertible {
        case fileMissing(URL)
        case missingField(String)
        case unreadable(String)

        var description: String {
            switch self {
            case .fileMissing(let url):
                return "hermes-version.txt missing at \(url.path)"
            case .missingField(let field):
                return "hermes-version.txt missing required field '\(field)'"
            case .unreadable(let why):
                return "hermes-version.txt unreadable: \(why)"
            }
        }
    }

    /// Resolves the bundle copy of `hermes-version.txt`. Returns nil if
    /// the bundle is missing the resource — callers can treat that as a
    /// dev-build that didn't run the bundler.
    static var bundledURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources
            .appendingPathComponent("hermes-runtime", isDirectory: true)
            .appendingPathComponent("hermes-version.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func read(from url: URL) throws -> HermesRuntimeVersion {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.fileMissing(url)
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ReadError.unreadable("\(error)")
        }
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        func required(_ key: String) throws -> String {
            guard let v = fields[key], !v.isEmpty else { throw ReadError.missingField(key) }
            return v
        }
        return HermesRuntimeVersion(
            hermesGitRef: try required("hermes_git_ref"),
            hermesVersion: try required("hermes_version"),
            pythonVersion: try required("python_version"),
            pythonBuild: try required("python_build"),
            bundledAt: try required("bundled_at")
        )
    }

    /// Short, single-line string for the Dev panel footer.
    /// Format: "Hermes <version> (<short-sha>) · Python <pyver>"
    /// e.g. "Hermes 0.13.0 (abc1234) · Python 3.11.15"
    var shortDisplayString: String {
        let shortSHA = String(hermesGitRef.prefix(7))
        return "Hermes \(hermesVersion) (\(shortSHA)) · Python \(pythonVersion)"
    }
}
