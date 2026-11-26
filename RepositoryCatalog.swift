import AppKit
import Foundation

struct LocalRepository: Identifiable, Sendable {
    let url: URL
    let lastModified: Date?
    let hasChanges: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var parentPath: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }

    init(url: URL, activity: GitActivity? = nil) {
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        lastModified = activity?.lastModified
        hasChanges = activity?.hasChanges ?? false
    }
}

@MainActor
final class RepositoryCatalog: ObservableObject {
    @Published private(set) var repositories: [LocalRepository] = []
    @Published private(set) var isImporting = false
    @Published private(set) var importMessage: String?

    private let defaults: UserDefaults
    private var manualPaths: Set<String>
    private var desktopPaths: Set<String>
    private var hiddenDesktopPaths: Set<String>
    private var activityByPath: [String: GitActivity] = [:]
    private var activityTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        manualPaths = Set(defaults.stringArray(forKey: "repositoryPaths") ?? [])
        desktopPaths = Set(defaults.stringArray(forKey: "desktopRepositoryPaths") ?? [])
        hiddenDesktopPaths = Set(defaults.stringArray(forKey: "hiddenDesktopRepositoryPaths") ?? [])
        updateRepositoryList()
    }

    func importDesktopRepositories() async {
        guard !isImporting else { return }
        isImporting = true
        importMessage = nil

        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try GitHubDesktopImport.repositories().map {
                    $0.resolvingSymlinksInPath().standardizedFileURL.path
                }
            }
        }.value

        switch result {
        case .success(let paths):
            let updatedPaths = Set(paths)
            if desktopPaths != updatedPaths {
                desktopPaths = updatedPaths
                defaults.set(desktopPaths.sorted(), forKey: "desktopRepositoryPaths")
                updateRepositoryList()
            }
        case .failure(let error):
            importMessage = error.localizedDescription
        }
        isImporting = false
        scanActivity()
    }

    func add(_ urls: [URL]) throws -> LocalRepository {
        var roots: [URL] = []
        for url in urls {
            let folder = url.resolvingSymlinksInPath()
            if Self.isWorkingTree(folder) {
                roots.append(folder)
            } else {
                let children = try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                )
                roots.append(contentsOf: children.map { $0.resolvingSymlinksInPath() }.filter(Self.isWorkingTree))
            }
        }

        let found = Self.sorted(Set(roots.map { $0.standardizedFileURL.path }).map { repository(at: $0) })
        guard let first = found.first else {
            throw CatalogError("Choose local Git repository folders or a folder that directly contains them.")
        }

        let existing = Set(repositories.map(\.id))
        let paths = found.map(\.id)
        manualPaths.formUnion(paths)
        hiddenDesktopPaths.subtract(paths)
        saveManualChanges()
        updateRepositoryList()
        scanActivity()
        return found.first { !existing.contains($0.id) } ?? first
    }

    func remove(_ repository: LocalRepository) {
        manualPaths.remove(repository.id)
        if desktopPaths.contains(repository.id) {
            hiddenDesktopPaths.insert(repository.id)
        }
        saveManualChanges()
        updateRepositoryList()
    }

    private func scanActivity() {
        activityTask?.cancel()
        let urls = repositories.map(\.url)
        activityTask = Task {
            let worker = Task.detached(priority: .utility) {
                var activity: [String: GitActivity] = [:]
                for url in urls {
                    if Task.isCancelled { break }
                    activity[url.path] = try? GitRepository.activity(at: url)
                }
                return activity
            }
            let activity = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            activityByPath = activity
            updateRepositoryList()
        }
    }

    private func repository(at path: String) -> LocalRepository {
        LocalRepository(url: URL(fileURLWithPath: path, isDirectory: true), activity: activityByPath[path])
    }

    private func updateRepositoryList() {
        let visiblePaths = manualPaths.union(desktopPaths.subtracting(hiddenDesktopPaths))
        repositories = Self.sorted(visiblePaths.map { repository(at: $0) })
    }

    private static func isWorkingTree(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }

    private static func sorted(_ repositories: [LocalRepository]) -> [LocalRepository] {
        repositories.sorted {
            let leftDate = $0.lastModified ?? .distantPast
            let rightDate = $1.lastModified ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    private func saveManualChanges() {
        defaults.set(manualPaths.sorted(), forKey: "repositoryPaths")
        defaults.set(hiddenDesktopPaths.sorted(), forKey: "hiddenDesktopRepositoryPaths")
    }

    private struct CatalogError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) { errorDescription = message }
    }
}

enum DesktopHandoff {
    static func open(_ repository: LocalRepository) async throws {
        guard
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.GitHubClient"),
            let helper = Bundle(url: appURL)?.url(forResource: "github", withExtension: "sh", subdirectory: "app/static"),
            FileManager.default.isExecutableFile(atPath: helper.path)
        else {
            throw HandoffError("GitHub Desktop or its command-line launcher couldn’t be found.")
        }

        let path = repository.url.path
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = helper
            process.arguments = [path]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw HandoffError(message.isEmpty ? "GitHub Desktop couldn’t open this folder." : message)
            }
        }.value
    }

    private struct HandoffError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }
}
