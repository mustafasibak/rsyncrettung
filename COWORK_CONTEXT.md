# RsyncRettung — Full Project Context (Handoff, 2026-07-08)

Self-contained briefing for anyone (human or Claude) picking up this project cold.

---

## 1. What the app is

**RsyncRettung** is a native macOS SwiftUI app (macOS-only, no iOS target) that backs up the **current user's home folder** to an external drive using `rsync`, and can restore from such a backup. The name is a German pun: "Rettung" = rescue/salvation.

- **Language/stack:** Swift / SwiftUI, single-file app
- **Xcode project:** `RsyncRettung.xcodeproj`
- **All app logic:** `RsyncRettung/ContentView.swift` (deliberately single-file)
- **Entry point:** `RsyncRettung/RsyncRettungApp.swift`
- **Bundled shell scripts** (app bundle Resources, run via `/bin/zsh`):
  - `SCRIPTS/rsync_swift.zsh` — backup. Args: `<DriveName> [--delete] [--include-trash] [--dry-run]`
  - `SCRIPTS/rsync_restore.zsh` — restore. Args: `<BackupFolderPath> [--dry-run] [--delete] [--skip-path=rel/path ...]`

**Hard constraint:** the app relies on the **stock macOS rsync** (openrsync on recent macOS). No Homebrew rsync, no `--info=progress2` — not available in this deployment.

---

## 2. Current repository state (important!)

- Branch `main`, 8 commits. **The last commit (7621db0) is from an earlier iteration — the entire 2026-07-07 batch is UNCOMMITTED:**
  - `ContentView.swift`: ~1,244 insertions / 281 deletions uncommitted (whole Restore tab, audit fixes 1–11, ETA/progress rework)
  - `SCRIPTS/rsync_swift.zsh`: modified uncommitted
  - `SCRIPTS/rsync_restore.zsh`: entirely new, untracked
  - `CLAUDE.md`: new, untracked
- **Backup flow was live-tested with a real 167 GB backup and works.** Restore flow live-test is still **pending**.
- Do **not** commit or push without the user explicitly asking (standing rule).

---

## 3. Features shipped (as of 2026-07-07)

| Feature | Where in code |
|---|---|
| Backup / Restore (Beta) tabs | `AppTab`, segmented picker (disabled while running/preparing) |
| Drive picker with hot-plug detection | `startVolumeWatcher()` — kqueue `DispatchSource` on `/Volumes` |
| Async space checks (backup: post-scan; restore: pre-flight with mirror delta) | `performPostScanSpaceCheck()`, `finishRestorePreparation()` |
| Accurate progress/ETA (hybrid byte + real per-file sizes) | `effectiveBackupDoneKB` / `effectiveRestoreDoneKB`, `etaSeconds` |
| Learned per-drive throughput for dry-run estimates | `storedSpeedKBps` / `recordSpeed`, UserDefaults key `measuredSpeedKBps_<DriveName>` |
| Color-coded log with throttled flushing (0.3 s, pinned + 500 cap) | `LogEntry`, `startLogFlushTimer()` |
| Mirror backup/restore with confirmation sheets | `showMirrorWarning`, `showRestoreMirrorWarning` |
| Cloud-services warning before real backups | `showCloudWarning` |
| Dry-run modes with summary stats + per-folder restore breakdown | `showDryRunSummary(label:)` |
| Restore folder-tree selection (per-folder checkboxes) | `restoreTreeItems`, `excludedRestorePaths` → `--skip-path=` |
| Include Trash toggle, Advanced Settings sheet | `includeTrash`, `showAdvancedSettings` |
| Skipped-files warning log on rsync exit 16/23/24 | `loadSkippedFiles(logFile:)`, `showSkippedFiles(_:limit:logPath:)` |
| Working Cancel (kills rsync via script-side signal trap) | trap block in both scripts |
| Finish banners (success / warnings / failed / cancelled) | `finishBanner(state:dryRun:)` |

**UI layout:** fixed 640 × 820 pt window; title switches with tab ("User Folder Backup" / "User Folder Restore"); tab picker · drive/folder picker · Start/Cancel · space-check line · log scroll (260/200 pt) · progress area · Advanced Settings (backup) or dry-run+mirror toggles (restore). Restore tab shows a beta note.

**Sheet flow:**
```
startBackup()  (async du → isPreparing)
  ├─ dryRunMode → proceedWithBackup() directly (skips both warning sheets)
  └─ else       → showCloudWarning sheet → proceedWithBackup()
mirrorMode toggle-on → showMirrorWarning sheet (restore has its own variant)
startRestore() → background measurement → finishRestorePreparation() → proceedWithRestore()
```

---

## 4. Architecture — Swift side (`ContentView.swift`)

### Process handling (identical pattern for backup and restore — do not change)
- Script launched via `Process` + a **single `Pipe` for stdout+stderr**; `readabilityHandler` parses chunks; sentinel lines are filtered from the visible log.
- **Completion runs on pipe EOF, not in `terminationHandler`.** A `DispatchGroup` tracks (a) every in-flight main-thread state update and (b) the termination handler (`group.enter()` before `process.run()`, `leave()` in the handler, which only stores `capturedExitStatus`). The EOF branch clears `readabilityHandler` (prevents retain/spin) and runs finish logic in `group.notify(queue: .main)`. This ordering is deliberate — moving completion back into `terminationHandler` reintroduces an exit-status race and drops the final output chunk.
- Exit codes: `0` success · `16/23/24` partial → skipped-files warning flow · `20` cancelled via signal trap · anything else failed. `userCancelled` overrides for display.
- `isPreparing` guards async pre-flight `du` measurements (Start buttons + tab picker disabled); `isRunning` guards the run.
- **All `du -sk` calls (`duKB`) run on background queues.** Never on the main thread — that was a shipped bug (UI froze every 2 s).
- **Both pipe handlers line-buffer** (`streamBuffer: Data`): chunks split at the last newline, decoded with lossy `String(decoding:as: UTF8.self)`; the tail waits for its newline (processed at EOF). Required for exact accounting — openrsync escapes non-ASCII filenames (umlauts!) with raw bytes that strict UTF-8 rejects. The scan-list file is decoded the same lossy way so map keys match live output exactly (verified with `Ördner mit Umlaut`).

### Progress / ETA system (real per-file sizes, stock-rsync compatible)
- Scripts run a pre-scan (`rsync --dry-run --stats --out-format='%l %n'`) into a `mktemp` file: the `--stats` block yields `XFER_KB=` (progress/ETA denominator); the `%l %n` lines are the **real byte size of every file this run will transfer**. For real runs the script emits `XFER_LIST=<path>`; Swift (`loadXferSizeList`) parses it off-main into `xferSizeByPath` / `restoreXferSizeByPath` (dirs/stats lines filtered), then deletes the file. **No estimated or average file sizes anywhere** — hard user requirement after an equal-size estimator showed 63 GB done at 20 GB written.
- Progress "done" = `max(du delta since baseline, realDoneBytes/1024)`, capped at xferTotal, made monotone via `backupDoneFloorKB` / `restoreDoneFloorKB` (raised each 2 s tick). `realDoneBytes` = sum of real sizes of *finished* files; the du delta covers the in-flight file's partial bytes (and overwrites keep progressing via the size map even when `du` stays flat).
- **Crediting** (`creditBackupFiles`/`creditRestoreFiles`): rsync `-v` prints a file name when it *starts* copying, so a file's size is credited only when the *next* file line appears (`*PendingFile`). File-line heuristic: starts with a letter, contains `/`, doesn't end in `/`, not a `deleting` line. Files finishing before the async map load land in `*UncreditedFiles`, credited when the map arrives (`*SizeMapLoaded`). Matched entries are removed from the map to prevent double-count.
- Baselines: `baselineTargetKB` = target `du` before backup; `restoreBaselineKB` = home `du` snapshot when the restore timer starts (fixes the bar pegging at 100 % on a non-empty home).
- ETA speed = `0.85 × cumulative average since transfer start + 0.15 × EMA` (`backupStartTime` set in `performPostScanSpaceCheck`, `restoreStartTime` on restore's `SCAN_END`). ETA computed **only on the 2 s timer ticks** (`updateBackupETA`/`updateRestoreETA` → `displayedBackupETA`/`displayedRestoreETA`), smoothed 0.7/0.3 against its previous value so log-flush re-renders can't flap it; first 15 s show "ETA: calculating…". The EMA (`speedKBps`, 2 s `du` sampling, 0.7/0.3) drives the live speed readout and **decays ×0.75 on zero-delta ticks** instead of freezing.
- `formatDuration` rounds on purpose: <90 s exact, <10 min half-minute steps, <1 h whole minutes (`~N min`), ≥1 h 5-minute steps. GB row labels: backup "new/changed data", restore "to restore".
- **Backup bar spans the full source size (2026-07-08):** `progress = (backupPreExistingKB + effectiveBackupDoneKB) / totalKB` with `backupPreExistingKB = totalKB − xferTotalKB`. `SegmentedProgressBar` renders pre-existing data as a striped light-accent segment (pre-filled when scan sentinels arrive) and this run's data as a solid accent segment; GB row reads `done / total · new/changed: x / y`. Restore tab unchanged.
- If `XFER_KB` is absent (scan failed), everything falls back to old `copiedKB/totalKB` math.
- Learned throughput: after a real run (≥10 s, exit 0/16/23/24), achieved KB/s is stored per drive (blended 50/50 with the previous value); dry-run summaries use it, falling back to a 50 MB/s assumption (`estimatedDryRunETA(forDrive:)`).

### Sentinel lines (stderr → `handleScriptOutput`, routed by `activeTab`)

| Sentinel | Emitted by | Meaning |
|---|---|---|
| `TOTAL_KB=` | both | total source size after excludes (**ignored on restore tab** — Swift computes its own total minus deselected folders) |
| `XFER_KB=` | both | bytes to transfer this run (pre-scan) |
| `XFER_LIST=` | both (real runs only) | path to mktemp file with `<bytes> <relpath>` per file; Swift deletes after parsing |
| `RAW_SOURCE_KB=` / `RAW_FILE_COUNT=` | backup | pre-exclude home size/count (dry-run summary) |
| `SCAN_START` / `SCAN_END` | both | pre-scan boundaries (spinner UI; restore sets `restoreStartTime`) |
| `TARGET=` / `SOURCE=` | backup / restore | resolved paths |
| `FILE_COUNT=` | restore | total files in backup (dry-run summary) |
| `HOME_RAW_KB=` / `HOME_SCOPED_KB=` | restore (dry-run) | home size raw / after excludes |
| `RUNNING_AS=` / `PWD=` | both | debug |

### Restore-tab specifics
- Folder picker + expandable per-folder checkbox tree (`restoreTreeItems`, `excludedRestorePaths` → `--skip-path=` args, trailing `/` appended for dirs).
- Space check in `finishRestorePreparation`: mirror mode needs only the net delta (source − current home, +10 %); plain restore conservatively requires full source size.
- Restore tab ignores the script's `TOTAL_KB` sentinel (would overwrite the deselection-adjusted total).

---

## 5. Architecture — shell side

Both scripts:
- Pre-scan with the identical exclude array, then run the real rsync. Stock flags: `-av --no-specials --partial --human-readable --modify-window=2`; restore adds `--ignore-errors`. Restore skips the pre-scan when the run itself is a dry run.
- **Run the main rsync in the background and `trap TERM/INT`**, forwarding the signal to `$RSYNC_PID` and exiting 20. Required because Swift's Cancel only SIGTERMs the zsh wrapper — without the trap, rsync keeps copying/deleting as an orphan. **Do not "simplify" back to a foreground call.**
- `--delete` passed only when the user enabled mirror mode (dry runs no longer force it).
- Error logs: backup → `$TARGET/rsync_errors.log` (dry run: `/tmp/rsync_dryrun_errors.log`); restore → `/private/tmp/rsync_restore_errors.log`.

### Exclude lists
Each script carries its **own separate exclude array — intentional** (restore additionally excludes `.DS_Store`, shell histories, and login-generated dotfiles so mirror-restore doesn't delete/clobber them). Keep them in sync manually when editing shared entries. Since 2026-06-26, Mail/Safari/Notes/Messages containers are **included** (explicit `--include` lines before the catch-all `com.apple.*` excludes — order matters). `*.app` is **not** excluded anywhere. Exclude categories: cloud/sync services, browser/Electron churn, system caches, Xcode artifacts, Office/Adobe containers, Apple group containers, sensitive preference plists.

---

## 6. Key bugs fixed (history)

1. Space check used stale `totalKB` → superseded by async `isPreparing` flow.
2. Drive picker not updating on hot-plug → kqueue watcher on `/Volumes`.
3. Dry-run showed progress bar / cloud warning / flooded log → spinner, direct proceed, 0.3 s log throttling.
4. *(2026-07-07)* **Restore exit-status race** — completion could read status before `terminationHandler` ran → false "success". Fixed via DispatchGroup/EOF pattern.
5. *(2026-07-07)* **Cancel left rsync running as an orphan** (kept copying/deleting after "Cancelled") — fixed with script-side TERM trap.
6. *(2026-07-07)* Restore script's `TOTAL_KB` overwrote the deselection-adjusted total — restore tab now ignores it.
7. *(2026-07-07)* `du` on the main thread froze the UI (start + every 2 s tick) — all moved to background queues.
8. *(2026-07-07)* Dry-run restore always passed `--delete` (showed deletions that would never happen) — removed.
9. *(2026-07-07)* Wrong error-log path in restore warnings — path now passed into `showSkippedFiles`.
10. *(2026-07-07)* Backup pipe handler never cleared + completion raced final output — EOF/group pattern ported to backup.
11. *(2026-07-07)* rsync exit 24 (vanished files) treated as hard failure — now handled like 23.
12. *(2026-07-07)* Full ETA/progress rework (see §4). Previously: frozen speed on stalls, restore bar pegged at 100 % on non-empty home, overwrite-blind byte counting, hardcoded 50 MB/s dry-run estimate, equal-size file estimator wildly off.

---

## 7. Coding rules (must follow)

- Single-file SwiftUI app — keep all logic in `ContentView.swift` unless explicitly asked to extract.
- No extra files, no MVVM refactor, no ObservableObject wrapper unless explicitly requested.
- Default to **no comments** in code edits; comment only when the WHY is non-obvious.
- **Never push to GitHub unless explicitly told.** Commit locally only when asked; never chain a push onto a commit.
- No backwards-compatibility hacks or dead code.
- Stock macOS rsync only (no Homebrew rsync, no `--info=progress2`).

---

## 8. Known open items (2026-07-07 audit, not yet implemented)

- Fixed `/tmp` log paths are symlink-attackable on multi-user Macs (should use `$TMPDIR`/`mktemp`); `/tmp/du_debug.txt` is leftover debug output.
- No Full Disk Access check — without FDA, Mail/Safari/Notes/Messages containers are silently skipped (backup-integrity risk).
- No warning when backing up secrets (Keychains, `.ssh`) to unencrypted drives.
- Non-mirror restore space check demands full source size (false negatives on re-restores).
- `gibString` prints "GB" but computes binary GiB; speed prints "MiB/s" — unit label mismatch.
- `detectDrives()` filters by hardcoded volume names instead of `volumeIsInternal`/`IsRemovable` resource keys.
- Exclude patterns are unanchored (`Library/Caches` also matches `Documents/…/Library/Caches`).
- `--skip-path` values are raw rsync patterns (a folder literally named `foo*` would over-match).
- Tracked `xcuserdata` scheme plist should be `git rm --cached`ed; `.DS_Store` missing from `.gitignore`.
- Ideas backlog: auto-scroll log, finish notification, app icon.

## 9. Immediate next steps

1. **Live-test the restore flow** (backup already validated with 167 GB real run).
2. Commit the 2026-07-07 batch once the user says so (everything in §2 is uncommitted).
3. Pick items from the §8 audit list as the user prioritizes them.
