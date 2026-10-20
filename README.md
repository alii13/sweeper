<p align="center">
  <img src="docs/banner.png" alt="Sweeper" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/dependencies-none-6b5cf6" alt="No dependencies">
</p>

A macOS app that finds stale git worktrees, build output and developer caches, and clears them in one click.

Worktrees pile up. Each one carries its own `node_modules` and Rust `target/`, so a few dozen of them quietly eat 50-100 GB. Sweeper shows every worktree on your machine sorted by size, tells you which ones are safe to delete, and clears them without touching anything that has unpushed or uncommitted work.

## How it decides

```mermaid
flowchart LR
    A["Scan ~ for git repos"] --> B["git worktree list"]
    B --> C["Measure each worktree<br/>size · last used · PR state"]
    C --> D{"Clean, pushed,<br/>not in use?"}
    D -- no --> E["Blocked<br/>shows the reason"]
    D -- yes --> F{"PR merged or closed,<br/>or idle 7+ days?"}
    F -- no --> G["Active"]
    F -- yes --> H["Stale<br/>one-click clear"]
    H --> I["Re-check, move out instantly,<br/>delete in the background"]
```

PR state comes from the GitHub CLI (`gh`). A squash-merged branch whose remote was deleted still counts as pushed when its PR head matches the local commit.

## How a delete works

```mermaid
sequenceDiagram
    participant You
    participant Sweeper
    participant git
    participant Disk
    You->>Sweeper: Clear stale
    Sweeper->>git: re-check status and unpushed commits
    git-->>Sweeper: still clean
    Sweeper->>Disk: rename folder into ~/.sweeper-trash (instant)
    Sweeper->>git: git worktree prune
    Sweeper-->>You: row gone
    Sweeper->>Disk: rm -rf in the background
    Sweeper-->>You: "Freed 12.4 GB"
```

Branches are never deleted, only the worktree folders.

## What it shows

- **Worktrees** across every repo in your home folder, sorted by size, with the PR state (via `gh`), when each was last used, and whether removing it would lose anything (uncommitted files, unpushed commits, a running process).
- **Caches**: Rust `target/` dirs, Cargo, npm, pnpm, bun, uv, pip, Go, Playwright, Hugging Face and Homebrew, each with a one-click clear.
- **Disk**: a drill-down map of your home folder and a list of files over 500 MB.

## Safety

- **Clear stale** only removes worktrees that are clean, fully pushed, not in use, and either have a merged or closed PR or have been idle for 7+ days. Each one is re-checked right before deletion.
- Branches are always kept.
- Anything riskier (in-use worktrees, uncommitted work, a whole repo) needs an explicit confirmation that lists what will be lost.

## Auto-sweep

The clock button in the toolbar installs a daily LaunchAgent (12:30) that runs the same safe sweep, deletes Rust targets idle for 3+ days, and prunes the pnpm store. It logs to `~/Library/Logs/Sweeper.log`.

## Build

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh      # builds, signs, and installs to /Applications
./release.sh    # builds dist/Sweeper-<version>.dmg
```

Signing uses the first "Developer ID Application" identity in your keychain, or ad-hoc if there is none. Set `SIGN_IDENTITY` to pick one, and `NOTARY_PROFILE` (a `notarytool store-credentials` profile) to notarize the DMG.

For the Disk tab to see Desktop, Documents, Downloads and other protected folders, add Sweeper under System Settings > Privacy & Security > Full Disk Access.
