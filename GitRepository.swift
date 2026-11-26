import Foundation
import Darwin

struct GitChange: Identifiable, Sendable {
    var id: String { indexStatus == "?" ? "?\u{0}" + path : path }
    let path: String
    let originalPath: String?
    let indexStatus: String
    let workTreeStatus: String
}

struct GitCommit: Identifiable, Sendable {
    let id: String
    let shortID: String
    let subject: String
    let relativeDate: String
}

struct GitSnapshot: Sendable {
    let branch: String
    let changes: [GitChange]
    let commits: [GitCommit]
}

struct GitActivity: Sendable {
    let lastModified: Date?
    let hasChanges: Bool
}

enum GitRepository {
    private static let diffLimit = 256 * 1024
    private static let listLimit = 8 * 1024 * 1024
    private static let patchOptions = [
        "--patch", "--unified=3", "--no-color", "--no-ext-diff", "--no-textconv",
        "--no-relative", "--submodule=short"
    ]

    static func snapshot(at repo: URL) throws -> GitSnapshot {
        let status = try readStatus(at: repo)
        let commits = status.hasCommits ? try recentCommits(at: repo) : []
        return GitSnapshot(branch: status.branch, changes: status.changes, commits: commits)
    }

    static func activity(at repo: URL) throws -> GitActivity {
        let status = try readStatus(at: repo)
        let branchTips = try run(at: repo, [
            "for-each-ref", "--count=1", "--sort=-committerdate", "--format=%(committerdate:unix)", "refs/heads"
        ], limit: 128)
        var newest = gitDate(branchTips.data)
        if status.isDetached {
            let head = try run(at: repo, [
                "log", "-1", "--format=%ct", "--no-notes", "--no-show-signature", "HEAD", "--"
            ], limit: 128)
            newest = later(newest, gitDate(head.data))
        }

        for change in status.changes {
            let file = repo.appendingPathComponent(change.path)
            newest = later(newest, modificationDate(at: file))
            if change.indexStatus == "D" || change.workTreeStatus == "D" {
                newest = later(newest, parentModificationDate(of: file, in: repo))
            } else if change.indexStatus == "R" || change.workTreeStatus == "R",
                      let originalPath = change.originalPath {
                newest = later(newest, parentModificationDate(of: file, in: repo))
                newest = later(newest, parentModificationDate(of: repo.appendingPathComponent(originalPath), in: repo))
            }
        }
        return GitActivity(lastModified: newest, hasChanges: !status.changes.isEmpty)
    }

    // A removal or rename can update only the containing directory.
    private static func parentModificationDate(of file: URL, in repo: URL) -> Date? {
        var parent = file.deletingLastPathComponent()
        while parent.path == repo.path || parent.path.hasPrefix(repo.path + "/") {
            if let date = modificationDate(at: parent) { return date }
            if parent.path == repo.path { break }
            parent.deleteLastPathComponent()
        }
        return nil
    }

    private static func modificationDate(at url: URL) -> Date? {
        url.withUnsafeFileSystemRepresentation { path -> Date? in
            var info = stat()
            guard let path, lstat(path, &info) == 0 else { return nil }
            let modified = info.st_mtimespec
            return Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1_000_000_000)
        }
    }

    private static func gitDate(_ data: Data) -> Date? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeInterval(text).map(Date.init(timeIntervalSince1970:))
    }

    private static func later(_ current: Date?, _ candidate: Date?) -> Date? {
        guard let candidate else { return current }
        return current.map { max($0, candidate) } ?? candidate
    }

    private static func readStatus(at repo: URL) throws -> (branch: String, changes: [GitChange], hasCommits: Bool, isDetached: Bool) {
        let status = try run(at: repo, [
            "status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all", "--renames"
        ], limit: listLimit)
        guard !status.truncated else { throw GitError("The repository has too many changes to list.") }

        let records = status.data.split(separator: 0, omittingEmptySubsequences: false)
        guard let header = records.first, header.starts(with: [35, 35, 32]) else {
            throw GitError("Git returned an unreadable branch status.")
        }
        let branchStatus = String(decoding: header.dropFirst(3), as: UTF8.self)
        let noCommitsPrefix = ["No commits yet on ", "Initial commit on "].first {
            branchStatus.hasPrefix($0)
        }
        let isDetached = branchStatus == "HEAD (no branch)"
        let branch: String
        if let noCommitsPrefix {
            branch = String(branchStatus.dropFirst(noCommitsPrefix.count))
        } else if isDetached {
            branch = "Detached HEAD"
        } else {
            branch = branchStatus.components(separatedBy: "...")[0]
        }

        var changes: [GitChange] = []
        var pending = records.dropFirst().dropLast().makeIterator()
        while let record = pending.next() {
            let codes = Array(record.prefix(3))
            guard codes.count == 3, codes[2] == 32 else {
                throw GitError("Git returned an unreadable file status.")
            }
            let path = try filePath(record.dropFirst(3))
            let indexStatus = String(UnicodeScalar(codes[0]))
            let workTreeStatus = String(UnicodeScalar(codes[1]))
            let hasOriginalPath = [indexStatus, workTreeStatus].contains { $0 == "R" || $0 == "C" }
            var originalPath: String?
            if hasOriginalPath {
                guard let original = pending.next() else {
                    throw GitError("Git did not return the original path for a renamed file.")
                }
                originalPath = try filePath(original)
            }
            changes.append(GitChange(path: path, originalPath: originalPath,
                                     indexStatus: indexStatus, workTreeStatus: workTreeStatus))
        }

        return (branch, changes, noCommitsPrefix == nil, isDetached)
    }

    static func diff(at repo: URL, change: GitChange) throws -> String {
        if change.indexStatus == "?" {
            if change.path.hasSuffix("/") {
                return "Git reports this directory as a separate repository. Open it separately to view its files."
            }
            let data = try run(at: repo, ["diff", "--no-index"] + patchOptions + ["--", "/dev/null", change.path],
                               limit: diffLimit, acceptsDifferences: true)
            return data.displayedDiff
        }

        let paths = [change.originalPath, change.path].compactMap { $0 }
        let unmergedStatus = change.indexStatus + change.workTreeStatus
        if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(unmergedStatus) {
            return try run(at: repo, ["diff", "--cc"] + patchOptions + ["--"] + paths,
                           limit: diffLimit).displayedDiff
        }

        var sections: [(title: String, patch: String)] = []
        if change.indexStatus != " " {
            let data = try run(at: repo, ["diff", "--cached", "--find-renames"] + patchOptions + ["--"] + paths,
                               limit: diffLimit)
            sections.append(("Staged", data.displayedDiff))
        }
        if change.workTreeStatus != " " {
            let data = try run(at: repo, ["diff", "--find-renames"] + patchOptions + ["--"] + paths,
                               limit: diffLimit)
            sections.append(("Unstaged", data.displayedDiff))
        }
        if sections.count == 1, let section = sections.first { return section.patch }
        return sections.map { "\($0.title)\n\n\($0.patch)" }.joined(separator: "\n\n")
    }

    static func commitDiff(at repo: URL, commit: GitCommit) throws -> String {
        try run(at: repo, ["show", "--format=", "--no-notes", "--no-show-signature",
                           "--diff-merges=first-parent", "--find-renames"] + patchOptions + [commit.id, "--"],
                limit: diffLimit).displayedDiff
    }

    private static func recentCommits(at repo: URL) throws -> [GitCommit] {
        let history = try run(at: repo, [
            "log", "-n", "40", "--no-notes", "--no-show-signature", "--encoding=UTF-8",
            "--format=%H%x00%h%x00%s%x00%cr", "-z", "HEAD", "--"
        ], limit: listLimit)
        guard !history.truncated else { throw GitError("The recent commit history is too large to list.") }
        let fields = history.data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        guard fields.count.isMultiple(of: 4) else {
            throw GitError("Git returned unreadable commit history.")
        }
        var commits: [GitCommit] = []
        for index in stride(from: 0, to: fields.count, by: 4) {
            commits.append(GitCommit(id: String(decoding: fields[index], as: UTF8.self),
                                     shortID: String(decoding: fields[index + 1], as: UTF8.self),
                                     subject: String(decoding: fields[index + 2], as: UTF8.self),
                                     relativeDate: String(decoding: fields[index + 3], as: UTF8.self)))
        }
        return commits
    }

    private static func filePath(_ bytes: Data.SubSequence) throws -> String {
        guard let path = String(data: bytes, encoding: .utf8), !path.isEmpty else {
            throw GitError("Git returned a filename that could not be read as UTF-8.")
        }
        return path
    }

    private static func run(at repo: URL, _ arguments: [String], limit: Int,
                            acceptsDifferences: Bool = false) throws -> CapturedOutput {
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) else {
            throw GitError("This folder is unavailable or no longer contains a Git working tree.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--no-optional-locks", "--literal-pathspecs", "-C", repo.path,
                             "-c", "core.fsmonitor=false", "-c", "core.quotePath=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        for variable in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_NAMESPACE",
                         "GIT_PREFIX", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                         "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"] {
            environment.removeValue(forKey: variable)
        }
        environment["LC_ALL"] = "C"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        // Read both streams concurrently so a full stderr pipe cannot block stdout.
        let stderr = ErrorStream()
        let readingError = DispatchGroup()
        readingError.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readingError.leave() }
            stderr.output = try? capture(errorPipe.fileHandleForReading, limit: 16 * 1024)
        }
        let capturedOutput = Result { try capture(outputPipe.fileHandleForReading, limit: limit) }
        process.waitUntilExit()
        readingError.wait()

        let output = try capturedOutput.get()
        let code = process.terminationStatus
        let details = stderr.output.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        let message = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedDifferences = acceptsDifferences && code == 1 && (!output.data.isEmpty || message.isEmpty)
        guard process.terminationReason == .exit,
              code == 0 || reportedDifferences else {
            throw GitError(message.isEmpty ? "Git exited with status \(code)." : message)
        }
        return output
    }

    private static func capture(_ handle: FileHandle, limit: Int) throws -> CapturedOutput {
        defer { try? handle.close() }
        var data = Data()
        var truncated = false
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            let available = limit - data.count
            data.append(chunk.prefix(available))
            truncated = truncated || chunk.count > available
        }
        return CapturedOutput(data: data, truncated: truncated)
    }
}

private struct GitError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

private struct CapturedOutput {
    let data: Data
    let truncated: Bool

    var displayedDiff: String {
        let text = String(decoding: data, as: UTF8.self)
        return truncated ? text + "\n\n[Diff truncated after 256 KiB]" : text
    }
}

/// Written by the stderr reader and read by the caller after its dispatch group completes.
private final class ErrorStream: @unchecked Sendable {
    var output: CapturedOutput?
}
