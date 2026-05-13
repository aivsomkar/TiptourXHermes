// TipTour/Agents/Skills/SkillImporter.swift

import Foundation

/// Fetches a GitHub repo's `.md` skill files and writes them into the
/// user's `SkillLibraryStore`. Reuses the same parser logic as
/// `BundledSkillSeeder` (via `SkillFrontmatterParser`) so an imported
/// skill is indistinguishable from a bundled one once on disk.
///
/// **Why GitHub-only:** the bundled sources (RuFlo, OpenWork) already
/// live there, and GitHub serves repo tarballs at a stable URL pattern
/// (`https://codeload.github.com/<owner>/<repo>/tar.gz/<branch>`) with
/// no auth required for public repos. GitLab/Bitbucket can be added
/// later by extending `parseGitHubURL` and the tarball URL builder.
actor SkillImporter {

    struct GitHubRef {
        let owner: String
        let repo: String
        let branch: String
        let subpath: String?
    }

    struct ImportReport: Sendable {
        let imported: [String]   // slugs of newly-written skills
        let skipped: [String]    // slugs that already existed
        let failed: [String]     // file basenames that couldn't be parsed
    }

    enum ImportError: Error, LocalizedError {
        case notAGitHubURL
        case malformedURL
        case unsupportedURLForm
        case downloadFailed(underlying: Error)
        case extractionFailed(reason: String)
        case noSkillsFound

        var errorDescription: String? {
            switch self {
            case .notAGitHubURL: return "URL must point to github.com"
            case .malformedURL: return "URL isn't well-formed — couldn't parse a host out of it"
            case .unsupportedURLForm: return "Paste a repo URL (https://github.com/owner/repo) or a tree URL (https://github.com/owner/repo/tree/<branch>/<path>). Blob, pull, commit, and issue URLs aren't supported."
            case .downloadFailed(let err): return "Download failed: \(err.localizedDescription)"
            case .extractionFailed(let reason): return "Extraction failed: \(reason)"
            case .noSkillsFound: return "No skill .md files found in the imported tree"
            }
        }
    }

    static func parseGitHubURL(_ raw: String) throws -> GitHubRef {
        guard let url = URL(string: raw), let host = url.host else {
            throw ImportError.malformedURL
        }
        guard host == "github.com" || host == "www.github.com" else {
            throw ImportError.notAGitHubURL
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw ImportError.malformedURL }
        let owner = parts[0]
        let repoRaw = parts[1]
        let repo = repoRaw.hasSuffix(".git") ? String(repoRaw.dropLast(4)) : repoRaw
        if parts.count >= 3, parts[2] != "tree" {
            // /blob, /pull, /commit, /issues, /actions, /wiki, etc — user
            // pointed at a non-tree resource. Surfacing a clear error is
            // better than silently downloading the whole repo at main.
            throw ImportError.unsupportedURLForm
        }
        if parts.count >= 4, parts[2] == "tree" {
            let branch = parts[3]
            let subpath = parts.count >= 5
                ? parts[4...].joined(separator: "/")
                : nil
            return GitHubRef(owner: owner, repo: repo, branch: branch, subpath: subpath)
        }
        return GitHubRef(owner: owner, repo: repo, branch: "main", subpath: nil)
    }
}

extension SkillImporter {

    /// Extract a `.tar.gz` into a fresh temp directory and return the URL.
    /// Uses `/usr/bin/tar` (present on every macOS); avoids pulling in a
    /// libarchive dependency. The caller is responsible for deleting the
    /// returned directory when finished.
    func extractTarball(at tarballURL: URL) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiptour-skill-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarballURL.path, "-C", dest.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        // Discard stdout to /dev/null rather than a buffered Pipe — tar's
        // -xzf stdout is empty in the success path, but a Pipe with no
        // reader could in theory block on a full buffer if tar ever
        // chattered. nullDevice removes that pathological case entirely.
        process.standardOutput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: dest)
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8) ?? "<unreadable>"
                    // Best-effort cleanup of the orphaned destination so a
                    // failed extraction doesn't leak an empty temp dir.
                    try? FileManager.default.removeItem(at: dest)
                    continuation.resume(throwing: ImportError.extractionFailed(
                        reason: errText.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                // Process.run() failed synchronously before terminationHandler
                // could ever fire (binary missing, permission denied, etc).
                // Clean up the temp dir and wrap the raw error in our typed
                // ImportError so callers see a consistent error shape.
                try? FileManager.default.removeItem(at: dest)
                continuation.resume(throwing: ImportError.extractionFailed(
                    reason: error.localizedDescription
                ))
            }
        }
    }
}

extension SkillImporter {

    /// Download `https://codeload.github.com/<owner>/<repo>/tar.gz/<branch>`
    /// to a temp file. Times out after 60 seconds.
    func downloadTarball(for ref: GitHubRef) async throws -> URL {
        // Percent-encode every URL component so owners/repos/branches with
        // `+`, `#`, spaces, or unicode characters produce a valid URL.
        // `.urlPathAllowed` deliberately keeps `/` unescaped — codeload
        // interprets `tar.gz/feature/foo` as the `feature/foo` branch, so
        // preserving the slash is required for branches with slashes.
        guard
            let owner = ref.owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let repo = ref.repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let branch = ref.branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            throw ImportError.malformedURL
        }
        let tarballURLString = "https://codeload.github.com/\(owner)/\(repo)/tar.gz/\(branch)"
        guard let tarballURL = URL(string: tarballURLString) else {
            throw ImportError.malformedURL
        }
        var request = URLRequest(url: tarballURL)
        request.timeoutInterval = 60
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ImportError.downloadFailed(
                    underlying: NSError(domain: "SkillImporter", code: http.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                )
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("tiptour-skill-tarball-\(UUID().uuidString).tar.gz")
            try data.write(to: dest)
            return dest
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.downloadFailed(underlying: error)
        }
    }
}

extension SkillImporter {

    /// Walk for `SKILL.md` files under `root` (optionally filtered to
    /// `subpath` relative to the GitHub tree URL the user pasted).
    /// Each match's parent folder IS the skill — per the agentskills.io
    /// spec, the folder name equals the skill name. Copy the entire
    /// parent folder into the store so `references/`/`templates/`/
    /// `scripts/`/`assets/` ride along.
    ///
    /// The store parameter is injectable for tests; production callers
    /// pass `SkillLibraryStore.shared`.
    func importFromExtractedDirectory(
        _ root: URL,
        subpath: String?,
        store: SkillLibraryStore
    ) async -> ImportReport {
        // GitHub tarballs unpack into a single top-level
        // `<repo>-<branch>/` directory; descend into that first so the
        // user-supplied subpath ("skills", ".agents/skills") matches.
        let topLevel = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.first ?? root
        let searchRoot: URL
        if let subpath, !subpath.isEmpty {
            searchRoot = topLevel.appendingPathComponent(subpath, isDirectory: true)
        } else {
            searchRoot = topLevel
        }

        var imported: [String] = []
        var skipped: [String] = []
        var failed: [String] = []

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ImportReport(imported: imported, skipped: skipped, failed: failed)
        }

        let existingSlugs = await store.existingSlugs()

        // Anchor on `SKILL.md`. Files like `references/REFERENCE.md`
        // are NOT enumerated as candidate skills — they ride along
        // when the parent folder is copied. Folders without a
        // `SKILL.md` are invisible to the importer entirely (they
        // don't show up in any of the three result buckets).
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "SKILL.md" {
            let parentFolder = fileURL.deletingLastPathComponent()
            let rawSlug = parentFolder.lastPathComponent
            let slug = SkillNameValidator.isValid(rawSlug) ? rawSlug : SkillNameValidator.sanitize(rawSlug)
            guard !slug.isEmpty else {
                failed.append(parentFolder.lastPathComponent)
                continue
            }
            if existingSlugs.contains(slug) {
                skipped.append(slug)
                continue
            }
            if let written = await store.installSkillFolder(slug: slug, source: parentFolder) {
                imported.append(written)
            } else {
                failed.append(parentFolder.lastPathComponent)
            }
        }

        return ImportReport(imported: imported, skipped: skipped, failed: failed)
    }

    /// Public entry point: parse the URL, download, extract, import.
    /// Cleans up its temp files on the way out.
    func importFrom(url: String, store: SkillLibraryStore = .shared) async throws -> ImportReport {
        let ref = try Self.parseGitHubURL(url)
        let tarball = try await downloadTarball(for: ref)
        defer { try? FileManager.default.removeItem(at: tarball) }

        let extracted = try await extractTarball(at: tarball)
        defer { try? FileManager.default.removeItem(at: extracted) }

        let report = await importFromExtractedDirectory(
            extracted,
            subpath: ref.subpath,
            store: store
        )
        if report.imported.isEmpty && report.skipped.isEmpty {
            throw ImportError.noSkillsFound
        }
        return report
    }
}
