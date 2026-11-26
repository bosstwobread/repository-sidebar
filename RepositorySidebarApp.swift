import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct RepositorySidebarApp: App {
    var body: some Scene {
        Window("Repository Sidebar", id: "repositories") {
            RepositoryWindow()
                .frame(minWidth: 850, minHeight: 460)
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
    }
}

private enum RepositoryTab: String, Hashable {
    case changes = "Changes"
    case history = "History"
}

private struct RepositoryWindow: View {
    @StateObject private var catalog = RepositoryCatalog()
    @AppStorage("selectedRepository") private var savedRepository = ""
    @State private var selectedRepository: String?
    @State private var tab: RepositoryTab = .changes
    @State private var refreshID = UUID()
    @State private var choosingFolders = false
    @State private var addError: String?
    @State private var repositoryFilter = ""

    private var repository: LocalRepository? {
        catalog.repositories.first { $0.id == selectedRepository }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 236)
            Rectangle().fill(DesktopPalette.border).frame(width: 1)

            Group {
                if let repository {
                    RepositoryInspector(repository: repository, tab: $tab, refreshID: refreshID, refresh: refresh)
                        .id(repository.id)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await catalog.importDesktopRepositories() }
        .onChange(of: catalog.repositories.map(\.id), initial: true) { _, ids in
            if let selectedRepository, ids.contains(selectedRepository) { return }
            selectedRepository = ids.contains(savedRepository) ? savedRepository : ids.first
        }
        .onChange(of: selectedRepository) { _, newSelection in
            if let newSelection { savedRepository = newSelection }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .fileImporter(isPresented: $choosingFolders, allowedContentTypes: [.folder],
                      allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                guard !urls.isEmpty else { return }
                selectedRepository = try catalog.add(urls).id
            } catch {
                addError = error.localizedDescription
            }
        }
        .alert("Couldn’t Add Repositories", isPresented: Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )) {
            Button("OK") { addError = nil }
        } message: {
            Text(addError ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Repository Sidebar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 15)
            .frame(height: DesktopPalette.toolbarHeight)
            .background(DesktopPalette.toolbar)
            if catalog.isImporting {
                ProgressView("Loading GitHub Desktop repositories…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Repository Selected", systemImage: "folder")
                } description: {
                    Text(catalog.importMessage ?? "Choose local Git repository folders or a folder that contains them.")
                } actions: {
                    HStack {
                        Button("Add Repositories…") { choosingFolders = true }
                        if catalog.importMessage != nil {
                            Button("Retry Import", action: refresh)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DesktopPalette.canvas)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Repositories", systemImage: "books.vertical")
                    .font(.system(size: 13, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    choosingFolders = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Add Repositories")
                .keyboardShortcut("o", modifiers: .command)
                .help("Add repository folders (⌘O)")
            }
            .padding(.horizontal, 12)
            .frame(height: DesktopPalette.toolbarHeight)
            .background(DesktopPalette.toolbar)

            FilterField(text: $repositoryFilter, prompt: "Filter repositories")
                .padding(8)
            Rectangle().fill(DesktopPalette.border).frame(height: 1)

            List(selection: $selectedRepository) {
                ForEach(catalog.repositories.filter {
                    repositoryFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(repositoryFilter)
                }) { repository in
                    repositoryRow(repository)
                        .tag(repository.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                        .help(repositoryHelp(repository))
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([repository.url])
                            }
                            Button("Remove from List") { remove(repository) }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .tint(DesktopPalette.blue)
            .accessibilityLabel("Repositories")

            if catalog.isImporting || (catalog.importMessage != nil && !catalog.repositories.isEmpty) {
                Rectangle().fill(DesktopPalette.border).frame(height: 1)
                HStack(spacing: 6) {
                    if catalog.isImporting {
                        ProgressView().controlSize(.mini)
                        Text("Loading repositories…")
                    } else if let message = catalog.importMessage {
                        Image(systemName: "exclamationmark.circle")
                        Text(message).lineLimit(2)
                        Spacer(minLength: 2)
                        Button("Retry", action: refresh)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        .background(DesktopPalette.canvas)
    }

    private func repositoryRow(_ repository: LocalRepository) -> some View {
        let selected = repository.id == selectedRepository
        return HStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Text(repository.parentPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if repository.hasChanges {
                Circle()
                    .fill(DesktopPalette.blue)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Uncommitted changes")
            }
        }
        .frame(height: 38)
        .contentShape(Rectangle())
    }

    private func repositoryHelp(_ repository: LocalRepository) -> String {
        guard let updated = repository.lastModified else { return repository.url.path }
        return "\(repository.url.path)\nModified \(updated.formatted(date: .abbreviated, time: .shortened))"
    }

    private func refresh() {
        refreshID = UUID()
        Task { await catalog.importDesktopRepositories() }
    }

    private func remove(_ repository: LocalRepository) {
        catalog.remove(repository)
        if selectedRepository == repository.id {
            selectedRepository = catalog.repositories.first?.id
        }
    }
}

private struct PreviewRequest: Hashable {
    let revision: UUID
    let tab: RepositoryTab
    let selectedID: String?
}

private struct PreviewResult {
    let request: PreviewRequest
    let result: Result<String, Error>
}

private struct RepositoryInspector: View {
    let repository: LocalRepository
    @Binding var tab: RepositoryTab
    let refreshID: UUID
    let refresh: () -> Void
    @State private var snapshot: GitSnapshot?
    @State private var snapshotError: String?
    @State private var isRefreshing = false
    @State private var selectedChange: String?
    @State private var selectedCommit: String?
    @State private var revision = UUID()
    @State private var preview: PreviewResult?
    @State private var handoffError: String?
    @State private var isOpeningDesktop = false
    @State private var changeFilter = ""

    private var previewRequest: PreviewRequest {
        PreviewRequest(revision: revision, tab: tab, selectedID: tab == .changes ? selectedChange : selectedCommit)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let snapshot {
                HSplitView {
                    entries(snapshot)
                        .frame(minWidth: 230, idealWidth: 275, maxWidth: 330, maxHeight: .infinity)
                    details(snapshot)
                        .frame(minWidth: 370, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let snapshotError {
                ContentUnavailableView("Couldn’t Read Repository", systemImage: "exclamationmark.triangle",
                                       description: Text(snapshotError))
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView("Reading repository…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DesktopPalette.canvas)
        .task(id: refreshID) { await loadSnapshot() }
        .task(id: previewRequest) { await loadPreview() }
        .alert("Couldn’t Open GitHub Desktop", isPresented: Binding(
            get: { handoffError != nil },
            set: { if !$0 { handoffError = nil } }
        )) {
            Button("OK") { handoffError = nil }
        } message: {
            Text(handoffError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            toolbarValue("Current Repository", value: repository.name, image: "book.closed")
                .help(repository.url.path)
                .accessibilityAddTraits(.isHeader)
            toolbarSeparator
            toolbarValue("Current Branch", value: snapshot?.branch ?? "—", image: "arrow.triangle.branch")
                .help(snapshot?.branch ?? "Current Branch")
            toolbarSeparator
            Button(action: refresh) {
                HStack(spacing: 8) {
                    if isRefreshing && snapshot != nil {
                        ProgressView().controlSize(.small).colorScheme(.dark)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15))
                    }
                    Text("Refresh").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 13)
                .frame(height: DesktopPalette.toolbarHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Reload the repository list and local changes (⌘R)")
            .keyboardShortcut("r", modifiers: .command)

            Spacer(minLength: 0)

            Button(action: openDesktop) {
                Label("Open in GitHub Desktop", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 29)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(isOpeningDesktop)
            .padding(.horizontal, 10)
        }
        .frame(height: DesktopPalette.toolbarHeight)
        .background(DesktopPalette.toolbar)
    }

    private var toolbarSeparator: some View {
        Rectangle().fill(.black.opacity(0.35)).frame(width: 1)
    }

    private func toolbarValue(_ label: String, value: String, image: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: image)
                .font(.system(size: 18))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.72))
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .truncationMode(.middle)
            }
            .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .frame(maxWidth: 195, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func entries(_ snapshot: GitSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(.changes, count: snapshot.changes.count)
                    .keyboardShortcut("1", modifiers: .command)
                Rectangle().fill(DesktopPalette.border).frame(width: 1)
                tabButton(.history)
                    .keyboardShortcut("2", modifiers: .command)
            }
            .frame(height: 34)
            Rectangle().fill(DesktopPalette.border).frame(height: 1)

            if tab == .changes {
                let count = snapshot.changes.count
                FilterField(text: $changeFilter, prompt: "Filter changes")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(DesktopPalette.panel)
                Rectangle().fill(DesktopPalette.border).frame(height: 1)
                Text(count == 1 ? "1 changed file" : "\(count) changed files")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(DesktopPalette.panel)
                Rectangle().fill(DesktopPalette.border).frame(height: 1)

                List(selection: $selectedChange) {
                    ForEach(snapshot.changes.filter {
                        changeFilter.isEmpty || $0.path.localizedCaseInsensitiveContains(changeFilter)
                    }) { change in
                        changeRow(change)
                            .tag(change.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 10))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .tint(DesktopPalette.blue)
                .accessibilityLabel("Changed files")
            } else {
                List(selection: $selectedCommit) {
                    ForEach(snapshot.commits) { commit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commit.subject.isEmpty ? "Untitled commit" : commit.subject)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2)
                            Text("\(commit.shortID) · \(commit.relativeDate)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 5)
                        .tag(commit.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .tint(DesktopPalette.blue)
                .accessibilityLabel("Recent commits")
            }
        }
    }

    private func tabButton(_ target: RepositoryTab, count: Int? = nil) -> some View {
        Button {
            tab = target
        } label: {
            HStack(spacing: 5) {
                Text(target.rawValue)
                    .font(.system(size: 13, weight: tab == target ? .semibold : .regular))
                if let count {
                    Text(count, format: .number)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DesktopPalette.counter, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if tab == target {
                    Rectangle().fill(DesktopPalette.blue).frame(height: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == target ? .isSelected : [])
    }

    private func changeRow(_ change: GitChange) -> some View {
        let name = (change.path as NSString).lastPathComponent
        let directory = (change.path as NSString).deletingLastPathComponent
        let status = change.workTreeStatus == " " ? change.indexStatus : change.workTreeStatus

        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                if !directory.isEmpty {
                    Text(directory + "/")
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                Text(name)
                    .layoutPriority(1)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: statusIcon(status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor(status))
                .frame(width: 14, height: 16)
                .accessibilityLabel(statusDescription(status))
        }
        .frame(height: 29)
        .contentShape(Rectangle())
        .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
    }

    private func details(_ snapshot: GitSnapshot) -> some View {
        let change = tab == .changes ? snapshot.changes.first { $0.id == selectedChange } : nil
        let commit = tab == .history ? snapshot.commits.first { $0.id == selectedCommit } : nil

        return VStack(alignment: .leading, spacing: 0) {
            if let title = change?.path ?? commit?.shortID {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(title)
                    Spacer(minLength: 6)
                    Image(systemName: tab == .changes ? "doc.text" : "clock")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(DesktopPalette.panel)
                Rectangle().fill(DesktopPalette.border).frame(height: 1)

                if let preview, preview.request == previewRequest {
                    switch preview.result {
                    case .success(let text) where !text.isEmpty:
                        DiffTextView(diff: text, showsFileHeaders: tab == .history)
                    case .success:
                        ContentUnavailableView("No Patch to Display", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure(let error):
                        ContentUnavailableView("Couldn’t Read Diff", systemImage: "exclamationmark.triangle",
                                               description: Text(error.localizedDescription))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ProgressView("Reading diff…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                let emptyText = tab == .changes
                    ? (snapshot.changes.isEmpty ? "No Local Changes" : "Select a Changed File")
                    : (snapshot.commits.isEmpty ? "No Commits Yet" : "Select a Commit")
                ContentUnavailableView(emptyText, systemImage: tab == .changes ? "doc.text" : "clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadSnapshot() async {
        isRefreshing = true
        let url = repository.url
        let work = Task.detached(priority: .userInitiated) { try GitRepository.snapshot(at: url) }

        do {
            let updated = try await work.value
            guard !Task.isCancelled else { return }
            snapshot = updated
            snapshotError = nil
            if !updated.changes.contains(where: { $0.id == selectedChange }) {
                selectedChange = updated.changes.first?.id
            }
            if !updated.commits.contains(where: { $0.id == selectedCommit }) {
                selectedCommit = updated.commits.first?.id
            }
        } catch {
            guard !Task.isCancelled else { return }
            snapshot = nil
            snapshotError = error.localizedDescription
        }

        revision = UUID()
        isRefreshing = false
    }

    private func loadPreview() async {
        guard let snapshot else { return }
        let request = previewRequest
        let url = repository.url
        let work: Task<String, Error>

        switch request.tab {
        case .changes:
            guard let change = snapshot.changes.first(where: { $0.id == request.selectedID }) else { return }
            work = Task.detached(priority: .userInitiated) { try GitRepository.diff(at: url, change: change) }
        case .history:
            guard let commit = snapshot.commits.first(where: { $0.id == request.selectedID }) else { return }
            work = Task.detached(priority: .userInitiated) { try GitRepository.commitDiff(at: url, commit: commit) }
        }

        let result = await work.result
        guard !Task.isCancelled, request == previewRequest else { return }
        preview = PreviewResult(request: request, result: result)
    }

    private func openDesktop() {
        isOpeningDesktop = true
        Task {
            defer { isOpeningDesktop = false }
            do {
                try await DesktopHandoff.open(repository)
            } catch {
                handoffError = error.localizedDescription
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "A", "?": return .green
        case "D", "U": return .red
        case "M", "T": return DesktopPalette.modified
        default: return DesktopPalette.blue
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "A", "?": return "plus.square"
        case "D": return "minus.square"
        case "R", "C": return "arrow.right.square"
        case "U": return "exclamationmark.square"
        default: return "dot.square"
        }
    }

    private func statusDescription(_ status: String) -> String {
        switch status {
        case "?": return "Untracked"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "U": return "Unmerged"
        case "T": return "Type changed"
        default: return "Modified"
        }
    }
}

private struct FilterField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(DesktopPalette.canvas, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focused ? DesktopPalette.blue : DesktopPalette.border)
                .allowsHitTesting(false)
        }
    }
}

private struct ToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0))
    }
}

private enum DesktopPalette {
    static let toolbarHeight: CGFloat = 50
    static let toolbar = Color(nsColor: adaptive(0x24292F, 0x161B22))
    static let canvas = Color(nsColor: canvasColor)
    static let panel = Color(nsColor: panelColor)
    static let border = Color(nsColor: borderColor)
    static let blue = Color(nsColor: adaptive(0x0969DA, 0x58A6FF))
    static let counter = Color(nsColor: adaptive(0xDDE1E6, 0x30363D))
    static let modified = Color(nsColor: adaptive(0x946200, 0xE3B341))

    static let canvasColor = adaptive(0xFFFFFF, 0x0D1117)
    static let panelColor = adaptive(0xF6F8FA, 0x161B22)
    static let borderColor = adaptive(0xD0D7DE, 0x30363D)
    static let lineAdded = adaptive(0xE6FFEC, 0x12261E)
    static let gutterAdded = adaptive(0xCCFFD8, 0x1C382A)
    static let lineRemoved = adaptive(0xFFEBE9, 0x2F1B20)
    static let gutterRemoved = adaptive(0xFFD7D5, 0x472329)
    static let lineHunk = adaptive(0xEFF6FF, 0x152132)
    static let gutterHunk = adaptive(0xDCEBFF, 0x1E3048)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                           green: CGFloat((value >> 8) & 0xff) / 255,
                           blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
    }
}

private struct DiffTextView: NSViewRepresentable {
    let diff: String
    let showsFileHeaders: Bool

    final class Coordinator {
        let storage = NSTextStorage()
        var displayedDiff: String?
        var displayedHeaders = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layoutManager = PatchLayoutManager()
        let unboundedSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let container = NSTextContainer(size: unboundedSize)
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        context.coordinator.storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let textView = PatchNSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isRichText = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = unboundedSize
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.backgroundColor = DesktopPalette.canvasColor
        textView.usesFindBar = true
        textView.setAccessibilityLabel("Diff")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = DesktopPalette.canvasColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.displayedDiff != diff || coordinator.displayedHeaders != showsFileHeaders else { return }
        coordinator.displayedDiff = diff
        coordinator.displayedHeaders = showsFileHeaders
        coordinator.storage.setAttributedString(PatchText(diff, showsFileHeaders: showsFileHeaders).string)
        (scroll.documentView as? NSTextView)?.scrollToBeginningOfDocument(nil)
    }
}

private final class PatchLine: NSObject {
    enum Kind {
        case ordinary, file, hunk, added, removed
    }

    static let attribute = NSAttributedString.Key("RepositorySidebarPatchLine")
    static let gutterAttribute = NSAttributedString.Key("RepositorySidebarPatchGutter")
    static let columnWidth = 6
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    let kind: Kind
    let before: Int?
    let after: Int?

    init(_ kind: Kind, before: Int? = nil, after: Int? = nil) {
        self.kind = kind
        self.before = before
        self.after = after
    }

    var gutterText: String { Self.number(before) + Self.number(after) }

    private static func number(_ value: Int?) -> String {
        let digits = value.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, columnWidth - 1 - digits.count)) + digits + " "
    }
}

private struct PatchText {
    let string: NSAttributedString

    init(_ patch: String, showsFileHeaders: Bool) {
        var lines = patch.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        let hidesHeaders = !showsFileHeaders && lines.contains { $0.hasPrefix("@@ ") }
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        paragraph.defaultTabInterval = 28
        let headerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        var oldNumber: Int?
        var newNumber: Int?

        for line in lines {
            let row: PatchLine
            switch line.first {
            case "@" where line.hasPrefix("@@"):
                let pieces = line.split(separator: " ", maxSplits: 4)
                oldNumber = pieces.count > 3 && pieces[0] == "@@" ? Self.start(from: pieces[1]) : nil
                newNumber = pieces.count > 3 && pieces[0] == "@@" ? Self.start(from: pieces[2]) : nil
                row = PatchLine(.hunk)
            case " " where oldNumber != nil || newNumber != nil:
                row = PatchLine(.ordinary, before: oldNumber, after: newNumber)
                oldNumber = oldNumber.map { $0 + 1 }
                newNumber = newNumber.map { $0 + 1 }
            case "+" where newNumber != nil:
                row = PatchLine(.added, after: newNumber)
                newNumber = newNumber.map { $0 + 1 }
            case "-" where oldNumber != nil:
                row = PatchLine(.removed, before: oldNumber)
                oldNumber = oldNumber.map { $0 + 1 }
            default:
                if line.hasPrefix("diff --") || line.isEmpty || line == "Staged" || line == "Unstaged" {
                    oldNumber = nil
                    newNumber = nil
                }
                if hidesHeaders, line.hasPrefix("diff --git ") || line.hasPrefix("index ")
                    || line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                    continue
                }
                row = PatchLine(line.hasPrefix("diff --") || line == "Staged" || line == "Unstaged" ? .file : .ordinary)
            }
            result.append(NSAttributedString(string: row.gutterText + " ", attributes: [
                .font: PatchLine.font,
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.secondaryLabelColor,
                PatchLine.attribute: row,
                PatchLine.gutterAttribute: true
            ]))
            result.append(NSAttributedString(string: line + "\n", attributes: [
                .font: row.kind == .file ? headerFont : PatchLine.font,
                .paragraphStyle: paragraph,
                .foregroundColor: row.kind == .hunk ? NSColor.secondaryLabelColor : NSColor.labelColor,
                PatchLine.attribute: row
            ]))
        }
        string = result
    }

    private static func start(from field: Substring) -> Int? {
        guard let number = field.dropFirst().split(separator: ",", maxSplits: 1).first,
              let value = Int(number), value >= 0, value < Int.max else { return nil }
        return value
    }
}

private final class PatchLayoutManager: NSLayoutManager {
    private let digitWidth = ("0" as NSString).size(withAttributes: [.font: PatchLine.font]).width

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let textView = textContainers.first?.textView, glyphsToShow.length > 0 {
            let rightEdge = MainActor.assumeIsolated { max(textView.bounds.maxX, textView.visibleRect.maxX) }
            enumerateLineFragments(forGlyphRange: glyphsToShow) { lineRect, _, _, glyphRange, _ in
                let character = self.characterIndexForGlyph(at: glyphRange.location)
                guard character < storage.length,
                      let line = storage.attribute(PatchLine.attribute, at: character, effectiveRange: nil) as? PatchLine else { return }

                let columnWidth = self.digitWidth * CGFloat(PatchLine.columnWidth)
                let gutter = NSRect(x: origin.x, y: lineRect.minY + origin.y,
                                    width: columnWidth * 2, height: lineRect.height)
                let colors = self.colors(for: line.kind)
                if let background = colors.background {
                    background.setFill()
                    NSRect(x: gutter.maxX, y: gutter.minY,
                           width: max(0, rightEdge - gutter.maxX), height: gutter.height).fill()
                }
                colors.gutter.setFill()
                gutter.fill()
                DesktopPalette.borderColor.setFill()
                NSRect(x: gutter.midX - 0.5, y: gutter.minY, width: 1, height: gutter.height).fill()
                NSRect(x: gutter.maxX - 1, y: gutter.minY, width: 1, height: gutter.height).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func colors(for kind: PatchLine.Kind) -> (background: NSColor?, gutter: NSColor) {
        switch kind {
        case .ordinary: return (nil, DesktopPalette.panelColor)
        case .file: return (DesktopPalette.panelColor, DesktopPalette.panelColor)
        case .hunk: return (DesktopPalette.lineHunk, DesktopPalette.gutterHunk)
        case .added: return (DesktopPalette.lineAdded, DesktopPalette.gutterAdded)
        case .removed: return (DesktopPalette.lineRemoved, DesktopPalette.gutterRemoved)
        }
    }
}

private final class PatchNSTextView: NSTextView {
    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { return }
        var plainText = ""
        let content = storage.string as NSString
        for value in selectedRanges {
            storage.enumerateAttribute(PatchLine.gutterAttribute, in: value.rangeValue) { isGutter, range, _ in
                if isGutter == nil { plainText.append(content.substring(with: range)) }
            }
        }
        guard !plainText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText, forType: .string)
    }
}
