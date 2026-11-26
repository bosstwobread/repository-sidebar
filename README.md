# Repository Sidebar

Repository Sidebar is a native macOS companion for GitHub Desktop. It keeps your local repositories in a permanent left pane alongside Changes, History, and a unified diff.

## Use the app

1. Open **Repository Sidebar.app** on macOS 14 or later.
2. Repositories registered in GitHub Desktop appear automatically. Click a repository to browse **Changes** and **History**.
3. For an additional repository, click **+** or press **⌘O**. Select repository folders or a folder that directly contains them.

The newest local changes appear first. For each repository, the app compares the newest local commit at a branch tip or detached HEAD with the newest modified or untracked file Git reports. For deletions and renames it also considers the containing directories. The list refreshes when the app opens or becomes active, and when you press **⌘R**.

Right-click a sidebar item for **Show in Finder** or **Remove from List**. The app remembers its own list and last selection locally. **Open in GitHub Desktop** hands the selected repository to GitHub Desktop.

The app reads GitHub Desktop 3.7’s local database and reads working trees through the system Git executable. History shows the 40 most recent commits on the current branch. Each diff section is capped at 256 KiB.

macOS may ask for permission to read repository folders in protected locations such as Documents or Desktop.

## Build from source

Use a Mac with the Xcode command-line tools and a macOS SDK. Run the following from this source directory.

```sh
./build.sh
open 'build/Repository Sidebar.app'
```

The build produces an ad hoc signed app with Apple Silicon and Intel slices.

The layout draws on [GitHub Desktop’s Changes and History views](https://docs.github.com/en/desktop/overview/creating-your-first-repository-using-github-desktop#part-3-exploring-github-desktop).
