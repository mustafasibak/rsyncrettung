# RsyncRettung — Project Context

## What this app is

RsyncRettung is a native macOS SwiftUI app (macOS-only, no iOS target) that backs up the **current user's home folder** to an external drive using `rsync`, and can restore from such a backup. The name is a German pun: "Rettung" = rescue/salvation.

- **Language:** Swift / SwiftUI
- **Xcode project:** `RsyncRettung.xcodeproj`
- **Main file:** `RsyncRettung/ContentView.swift` (single-file app, all logic here)
- **App entry point:** `RsyncRettung/RsyncRettungApp.swift`
- **Bundled scripts (app bundle Resources, run via `/bin/zsh`):**
  - `SCRIPTS/rsync_swift.zsh` — backup
  - `SCRIPTS/rsync_restore.zsh` — restore

The app relies on the **stock macOS rsync** (openrsync on recent macOS). Do not introduce a dependency on Homebrew rsync / `--info=progress2` — not available in this deployment.

---

## Architecture

### Swift side (`ContentView.swift`)

Two tabs (`AppTab`): **Backup** and **Restore (Beta)**, switched by a segmented picker (disabled while running/preparing).

**Process handling (both flows use the same pattern):**
- Script launched via `Process` + a single `Pipe` for stdout+stderr.
- `readabilityHandler` parses output chunks; sentinel lines (below) are filtered out of the visible log.
- **Completion runs on pipe EOF, not in `terminationHandler`.** A `DispatchGroup` tracks (a) every in-flight main-thread state update and (b) the termination handler (`group.enter()` before `process.run()`, `leave()` in the handler, which only stores `capturedExitStatus`). The EOF branch clears `readabilityHandler` (prevents retain/spin) and runs the finish logic in `group.notify(queue: .main)`. This ordering is deliberate — do not move completion logic back into `terminationHandler` (exit-status race, missing final output chunk).
- Exit codes: `0` success · `16/23/24` partial → skipped-files warning flow · `20` = cancelled via signal trap · anything else = failed. `userCancelled` overrides the code for display.
- `isPreparing` guards the async pre-flight `du` measurements (Start buttons + tab picker disabled); `isRunning` guards the actual run.
- **All `du -sk` calls (`duKB`) run on background queues.** Never call `duKB` on the main thread — that was a shipped bug (UI froze every 2 s).

**Progress / ETA system (real per-file sizes since 2026-07-07, stock-rsync compatible):**
- The scripts run a pre-scan (`rsync --dry-run --stats --out-format='%l %n'`) whose output goes to a `mktemp` file: the `--stats` block yields `XFER_KB=` (progress/ETA denominator), and the `%l %n` lines are the **real byte size of every file this run will transfer**. For real runs the script emits `XFER_LIST=<path>`; Swift (`loadXferSizeList`) parses it off-main into `xferSizeByPath` / `restoreXferSizeByPath` (dirs and stats lines filtered out) and deletes the file. **No estimated or average file sizes anywhere** — a user requirement after the equal-size file-count estimator showed 63 GB done at 20 GB written.
- Progress "done" value = `effectiveBackupDoneKB` / `effectiveRestoreDoneKB` = `max(du delta since baseline, realDoneBytes/1024)`, capped at xferTotal, monotone via `backupDoneFloorKB` / `restoreDoneFloorKB` (raised each 2 s tick). `realDoneBytes` = sum of real sizes of *finished* files; the du delta covers the in-flight file's partial bytes (and overwrites keep progressing via the size map even when `du` stays flat).
- **Backup bar spans the full source size (since 2026-07-08):** `progress` = `(backupPreExistingKB + effectiveBackupDoneKB) / totalKB`, where `backupPreExistingKB = totalKB − xferTotalKB` (data already on the drive). Rendered by `SegmentedProgressBar` (top-level struct): striped light-accent segment = pre-existing data (jumps in when the scan sentinels arrive), solid accent segment = this run's new/changed data. Percentage matches the full-size fraction. GB row: `done / total  ·  new/changed: x / y`. Restore tab still uses the plain per-run `ProgressView`. The `xferTotalKB == 0` fallback path is unchanged.
- **Crediting** (`creditBackupFiles`/`creditRestoreFiles`): rsync `-v` prints a file name when it *starts* copying, so a file's size is credited only when the *next* file line appears (`*PendingFile`). File lines detected by heuristic: starts with a letter, contains `/`, doesn't end in `/`, not a `deleting` line. Files finishing before the async map load land in `*UncreditedFiles` and are credited when the map arrives (`*SizeMapLoaded` flag). Matched entries are removed from the map to prevent double-count.
- **Both pipe handlers line-buffer** (`streamBuffer: Data`): chunks are split at the last newline and decoded with lossy `String(decoding:as: UTF8.self)`; the tail waits for its newline (processed at EOF). Required for exact accounting — and openrsync escapes non-ASCII filenames (umlauts!) with raw bytes that strict UTF-8 decoding rejects; the scan-list file is decoded the same lossy way so map keys match the live output exactly (verified with `Ördner mit Umlaut`).
- Baselines: `baselineTargetKB` = target `du` before backup; `restoreBaselineKB` = home `du` snapshot when the restore timer starts (fixes the bar pegging at 100 % on a non-empty home).
- ETA speed = `0.85 × cumulative average since transfer start + 0.15 × EMA` (`backupStartTime` set in `performPostScanSpaceCheck`, `restoreStartTime` on the restore tab's `SCAN_END`). ETA is computed **only on the 2 s timer ticks** (`updateBackupETA`/`updateRestoreETA` → `displayedBackupETA`/`displayedRestoreETA`), smoothed 0.7/0.3 against its previous value so log-flush re-renders can't make it flap; first 15 s show "ETA: calculating…". The EMA (`speedKBps`, 2 s `du` sampling, 0.7/0.3 weights) is kept for the live speed readout and **decays ×0.75 on zero-delta ticks** instead of freezing.
- `formatDuration` rounds on purpose: <90 s exact seconds, <10 min half-minute steps, <1 h whole minutes (`~N min`), ≥1 h 5-minute steps (`~N h M min`). GB row labels: backup "new/changed data", restore "to restore" (was "this run", which users misread as pre-existing data).
- If `XFER_KB` is absent (scan failed), everything falls back to the old `copiedKB/totalKB` math.
- **Learned throughput:** after a real run (≥10 s, exit 0/16/23/24), the achieved KB/s is stored in `UserDefaults` under `measuredSpeedKBps_<DriveName>` (blended 50/50 with the previous value). Dry-run summaries use the drive's stored speed, falling back to a 50 MB/s assumption (`estimatedDryRunETA(forDrive:)`).

**Sentinel lines (stderr → parsed in `handleScriptOutput`, routed by `activeTab`):**

| Sentinel | Emitted by | Meaning |
|---|---|---|
| `TOTAL_KB=` | both | total source size after excludes (backup: from scan; **ignored on restore tab** — Swift computes its own total minus deselected folders) |
| `XFER_KB=` | both | bytes to transfer this run (from pre-scan) |
| `XFER_LIST=` | both (real runs only) | path to mktemp file with `<bytes> <relpath>` per to-transfer file (real-size progress map; Swift deletes it after parsing) |
| `RAW_SOURCE_KB=` / `RAW_FILE_COUNT=` | backup | pre-exclude home size/count (dry-run summary) |
| `SCAN_START` / `SCAN_END` | both | pre-scan boundaries (spinner UI; restore sets `restoreStartTime`) |
| `TARGET=` / `SOURCE=` | backup / restore | resolved paths |
| `FILE_COUNT=` | restore | total files in backup (dry-run summary) |
| `HOME_RAW_KB=` / `HOME_SCOPED_KB=` | restore (dry-run) | home size raw / after excludes |
| `RUNNING_AS=` / `PWD=` | both | debug |

**Other Swift details:**
- Volume hot-plug watcher: kqueue `DispatchSource` on `/Volumes` (`startVolumeWatcher`).
- Log buffered in `pendingLogEntries`, flushed by 0.3 s timer, capped at pinned + 500 entries.
- Restore tab: folder picker + expandable per-folder checkbox tree (`restoreTreeItems`, `excludedRestorePaths` → `--skip-path=` args, trailing `/` appended for dirs).
- Restore space check: mirror mode needs only the net delta (source − current home, +10 %); plain restore conservatively requires full source. Runs in `finishRestorePreparation` after background measurement.
- `showSkippedFiles(_:limit:logPath:)` — the log path is passed in (backup and restore have different logs).

### Shell side

**`rsync_swift.zsh`** — args: `<DriveName> [--delete] [--include-trash] [--dry-run]`
**`rsync_restore.zsh`** — args: `<BackupFolderPath> [--dry-run] [--delete] [--skip-path=rel/path ...]`

Both scripts:
- Pre-scan with the identical exclude array, then run the real rsync (stock flags: `-av --no-specials --partial --human-readable --modify-window=2`; restore adds `--ignore-errors`). Restore skips the pre-scan when the run itself is a dry run.
- **Run the main rsync in the background and `trap TERM/INT`**, forwarding the signal to `$RSYNC_PID` and exiting 20. Required because Swift's Cancel only SIGTERMs the zsh wrapper — without the trap, rsync keeps copying/deleting as an orphan. Do not "simplify" this back to a foreground call.
- `--delete` is passed only when the user enabled mirror mode (dry runs no longer force it).
- Error logs: backup → `$TARGET/rsync_errors.log` (dry run: `/tmp/rsync_dryrun_errors.log`); restore → `/private/tmp/rsync_restore_errors.log`.

---

## Features shipped (as of 2026-07-07)

| Feature | Where |
|---|---|
| Backup/Restore tabs | `AppTab`, segmented picker |
| Drive picker with hot-plug detection | `startVolumeWatcher()` |
| Async space checks (backup: post-scan; restore: pre-flight with mirror delta) | `performPostScanSpaceCheck()`, `finishRestorePreparation()` |
| Accurate progress/ETA (hybrid byte+file, cumulative-avg blend) | `effective*DoneKB`, `etaSeconds`, `restoreETASeconds` |
| Learned per-drive throughput for dry-run estimates | `storedSpeedKBps` / `recordSpeed` |
| Color-coded log with throttled flushing | `LogEntry`, `startLogFlushTimer()` |
| Mirror backup/restore with confirmation sheets | `showMirrorWarning`, `showRestoreMirrorWarning` |
| Cloud-services warning before real backups | `showCloudWarning` |
| Dry-run modes with summary stats + per-folder restore breakdown | `showDryRunSummary(label:)` |
| Restore folder-tree selection (per-folder checkboxes) | `restoreTreeItems`, `--skip-path=` |
| Include Trash toggle, Advanced Settings sheet | `includeTrash`, `showAdvancedSettings` |
| Skipped-files log on exit 16/23/24 | `loadSkippedFiles(logFile:)` |
| Working Cancel (kills rsync via script signal trap) | trap block in both scripts |
| Finish banners (success/warnings/failed/cancelled) | `finishBanner(state:dryRun:)` |

---

## Shipped 2026-10-14 (pre-IT-ticket hardening)

- **Stall timeout + watchdog:** main rsync in both scripts runs with `--whole-file --timeout=300`. openrsync then logs `poll: timeout` but can still block forever in `wait4` on the stuck peer process (verified with a SIGSTOP'd receiver), so each script polls its error log every 1 s and on `poll: timeout` SIGKILLs rsync + children and exits **30**. Swift shows a dedicated exit-30 message on both tabs. `--whole-file` is required so the delta pass on a large changed file can't trigger a false timeout. Verified: normal → 0, stall → 30, Cancel → 20, no orphans. A full dry-run walk of a 291 GB home with `--timeout=2` did not trip (file-list building doesn't count as idle).
- **Restore early-stop detection:** `restoreLogShowsEarlyStop` — `unexpected end of file` in the restore error log (any non-0/30 exit, real runs) → failed state with "may have stopped early" message. Reproduced: killing the receiver gave exit **16**, that exact log line, and 6/40 files — previously reported as success.
- **FDA sheet for MDM rollout:** text now says IT grants it; real runs are blocked without FDA, only dry runs can continue (`fdaPendingIsDryRun`).
- **Backup `/tmp` paths fixed:** `du` debug output → `/dev/null`; dry-run error log via `mktemp`, passed to Swift with new `ERROR_LOG=` sentinel (`backupErrorLogPath`).
- `/Creative Cloud Files*` excluded (both scripts).
- `ENABLE_HARDENED_RUNTIME = YES` (only takes effect once signed with a real identity — ad-hoc builds still show `flags=0x2(adhoc)`).
- **`awk` locale bug fixed:** `SCAN_KB`/`XFER_KB` parsing now runs `LC_ALL=C awk`. Under a UTF-8 locale (e.g. a terminal with `LANG=de_DE.UTF-8`) BSD awk aborted with "towc: multibyte conversion failure" on openrsync's raw-byte filenames in the scan list, so `TOTAL_KB`/`XFER_KB` were silently never emitted and the app fell back to the old rough progress math. GUI launches usually have no `LANG`, so app runs were probably unaffected, but it was fragile.
- **ETA averaging slowed to ~2 min:** ETA now uses `longSpeedKBps` alone, with EMA weights 0.985/0.015 per 2 s tick (decay 0.995 on zero-delta ticks); `speedKBps` is only the live speed readout. Measured by recording a real 86.6 GiB backup (home → `Mustafa-1208492`, 13 min, every output line + 2 s `du` samples) and replaying it through the app's exact math: old ~20 s average → median error 28 %, worst 336 %, ETA climbed 9 → 22 min during small-file stretches; new → median 12 %, 90 % within 26 %, worst 29 %, max rise +1 % per tick, steady countdown, slightly optimistic (−10…−25 %). Same constants applied to restore (not separately measured). One recording only; multi-hour runs not yet measured.

- **Restore onto a Mac in use:** real restores now always measure the home folder (`du`, off main). Above `restoreInUseThresholdKB` (5 GB) a red-tinted sheet (`showRestoreInUseWarning`) explains that newer files on this Mac get overwritten and requires a checkbox before continuing to the FDA check. Dry runs skip it.
- **Backup early-stop message:** `logShowsEarlyStop` (renamed from `restoreLogShowsEarlyStop`) is now also checked on backup; a crash gives "Backup stopped early … incomplete" instead of "failed (code 16)".
- Restore tab shows "Free on this Mac" under the drive picker (`macFreeSpaceMessage`, refreshed on appear and after each restore); restore space messages say "on this Mac"; the restore free-space check uses `NSHomeDirectory()`.
- Both scripts no longer print "✅ … complete!" during dry runs.
- **UI text style rule:** no dashes or em dashes in user-facing strings (user preference). Existing strings were rewritten with periods/colons; missing values show "n/a". Commit messages: no dashes, no Co-Authored-By line.
- Calendar/Reminders (`group.com.apple.calendar`/`.reminders`) are deliberately still excluded: user's calendars come from Exchange.

## Shipped 2026-08-12 → 2026-09-22 (committed 2026-10-14 as `27ac2ff`)


- **Full Disk Access pre-flight check — implemented AND wired in.** `hasFullDiskAccess()` / `checkFullDiskAccess(then:)` (~`ContentView.swift:2021`) check readability of `~/Library/Application Support/com.apple.TCC` (a reliable FDA canary — deliberately not a stat check, since TCC only gates actual reads). `checkFullDiskAccess` is called from `startBackup()` (~line 976, gates `proceedWithBackup`/cloud warning) and from the restore space-check flow (~line 1260, gates `proceedWithRestore`) — shows a warning sheet if FDA is missing (since 2026-10-14: refers the user to IT, blocks real runs, dry runs only). This resolves [[project_fda_diagnosis_aug7]] and the old "No Full Disk Access check" open item below.
- Adobe excludes added: `Application Support/Adobe/Common/Media Cache Files`, `Media Cache`, `Peak Files` (both scripts).
- Office group-container excludes expanded: `MicrosoftRegistrationDB`, `SolutionPackagesLock`, `TemporaryItems`, `.com.apple.containermanagerd.metadata.plist`; `Library/Logs/DiagnosticReports/Retired` excluded.
- Restore error log moved off `/tmp` to `$HOME/Desktop/RsyncRettung_restore_errors.log` (backup side fixed 2026-10-14, see above).
- Restore exit code 12 (protocol stream error) now treated as a possible-skips case alongside 16/23/24.
- Backup and restore now keep separate log arrays (`backupLogEntries`/`restoreLogEntries`) — switching tabs no longer mixes logs.
- Quick free-space readout on drive selection (`updateDriveFreeSpaceMessage`), ahead of the accurate post-scan check.
- "bin noch dran" beta caption removed from the Restore tab.
- **Units (2026-10-14): all display is decimal, Finder-style** — `gbString` (`%.2f GB`, 1 GB = 10⁹ bytes) and `speedString` (`MB/s`); internal values stay du's 1024-byte KB. Replaced the earlier GiB/MiB labels, which didn't match Finder (93 GB showed as 86.61 GiB) and mixed with a mislabeled binary "MB/s" in the dry-run note.
- ETA jumpiness fix: both speed EMAs now source from `effectiveBackupDoneKB`/`effectiveRestoreDoneKB` deltas instead of raw `du` growth (`lastEffectiveBackupDoneKB`/`lastEffectiveRestoreDoneKB`); added a second, slower `longSpeedKBps`/`longRestoreSpeedKBps` EMA (~20s time constant) to kill early-run volatility in the cumulative-average term; display smoothing tightened 0.7/0.3 → 0.8/0.2. Build-verified (`xcodebuild` succeeded); not yet re-confirmed against a real backup for jumpiness.
- `detectDrives()` already filters by `volumeIsInternal`/`volumeIsLocal`/`volumeIsRootFileSystem` — the "hardcoded volume names" open item below was stale even before this batch.
- App icon exists (`AppIcon-1024.png`) — the "ideas: app icon" item below was stale.

A German-language draft security/IT-review ticket for RsyncRettung lives at `~/Desktop/rsyncrettung_security_review_ticket_de.md` (intentionally kept out of the repo, not git-tracked, written 2026-08-12 against commit `4767f86`). It has several `[ENTSCHEIDEN]` (decide) placeholders — company Developer ID/bundle ID, notarization requirement, MDM PPPC policy for FDA, target team/use case — that need the user's input before it can be submitted. Its §4 (FDA status) is now stale as of this check and should be updated to "implemented and wired in" before submission.

---

## UI layout

- Fixed window: **640 × 820 pt**
- Title switches with tab ("User Folder Backup" / "User Folder Restore")
- Tab picker · drive picker(s) · Start/Cancel · space-check line · log scroll view (260/200 pt) · progress area · Advanced Settings (backup) / dry-run+mirror toggles (restore)
- Restore tab still shows a "bin noch dran" beta note

## Sheet flow

```
startBackup()  (async du → isPreparing)
  ├─ dryRunMode  → proceedWithBackup() directly (skips both warning sheets)
  └─ else        → showCloudWarning sheet → proceedWithBackup()
mirrorMode toggle-on → showMirrorWarning sheet (also restore variant)
startRestore() → background measurement → finishRestorePreparation() → proceedWithRestore()
```

---

## Key bugs fixed (history)

1. **Space check used stale `totalKB`** — fixed by measuring synchronously… later superseded by async `isPreparing` flow.
2. **Drive picker not updating on hot-plug** — kqueue watcher on `/Volumes`.
3. **Dry-run showed progress bar / cloud warning / flooded log** — spinner, direct proceed, 0.3 s log throttling.
4. *(2026-07-07 batch)* **Restore exit-status race** — completion could read status before `terminationHandler` ran → false "success". Fixed via DispatchGroup pattern (see Architecture).
5. *(2026-07-07)* **Cancel left rsync running as an orphan** (still copying/deleting after "Cancelled") — fixed with script-side TERM trap.
6. *(2026-07-07)* **Restore script's `TOTAL_KB` overwrote the deselection-adjusted total** — restore tab now ignores that sentinel.
7. *(2026-07-07)* **`du` on the main thread froze the UI** (start of backup/restore + every 2 s timer tick) — all moved to background queues.
8. *(2026-07-07)* **Dry-run restore always passed `--delete`** — showed deletions that would never happen; removed.
9. *(2026-07-07)* **Wrong error-log path in restore warnings** — path now passed into `showSkippedFiles`.
10. *(2026-07-07)* **Backup pipe handler never cleared + completion raced final output** — ported EOF/group pattern to backup.
11. *(2026-07-07)* **rsync exit 24 (vanished files) treated as hard failure** — now handled like 23.
12. *(2026-07-07)* **ETA rework** — see "Progress / ETA system". Previously: frozen speed on stalls, pegged restore bar on non-empty home, overwrite-blind byte counting, hardcoded 50 MB/s dry-run estimate.

---

## Coding rules for this project

- Single-file SwiftUI app — keep all logic in `ContentView.swift` unless the user asks to extract.
- No extra files, no MVVM refactor, no ObservableObject wrapper unless explicitly requested.
- Default to **no comments** in code edits. Only add a comment when the WHY is non-obvious.
- Do not push to GitHub unless the user explicitly says to push. Commit locally only when asked; never chain a push onto a commit automatically.
- No backwards-compatibility hacks or dead code.
- Stock macOS rsync only (no Homebrew rsync dependency, no `--info=progress2`).

---

## Exclude lists

Both scripts carry their **own separate exclude array — intentional** (backup and restore have different needs; e.g. restore additionally excludes `.DS_Store`, shell histories, and login-generated dotfiles so mirror-restore doesn't delete/clobber them). Keep them in sync manually when editing shared entries. Since 2026-06-26 Mail/Safari/Notes/Messages containers are **included** (explicit `--include` lines before the catch-all `com.apple.*` excludes — order matters). `*.app` is **no longer excluded** anywhere.

**2026-07-08 revision (generalized for sharing the app; comments now plain German):**
- Root-level patterns are **anchored**: `/.Trash*`, `/Nextcloud*` (unanchored they also hit e.g. `Documents/Nextcloud Notizen`). The deeper `Library/...` patterns stay deliberately unanchored so they also match caches *inside* the included Mail/Safari/Notes/SMS containers.
- **Office fix:** the blanket `UBF8T346G9.Office/` exclude is gone — it would silently drop classic-Outlook mailboxes (`…/Outlook/Outlook 15 Profiles`) and user templates on colleagues' Macs. Only `SolutionPackages`, `FontCache`, `ComRPC32` are excluded now.
- **Restore fix:** `iCloud Drive*` → exact `/iCloud Drive/` (the old pattern also blocked restoring a real folder like `iCloud Drive (Archiv)`).
- **New excludes** (post-FDA the TCC-protected system junk started flowing in, seen re-transferring every run): `Library/Trial`, `DuetExpertCenter`, `IntelligencePlatform`, `com.apple.aiml.instrumentation`, `Weather`, `Suggestions`, `Application Support/Knowledge`, `DifferentialPrivacy`, `Application Support/CloudDocs`, `Application Support/com.apple.wallpaper/aerials` (457 MB re-downloadable videos; `Store/` with the settings stays in).
- **New "Misc." category** for case-specific entries few Macs have: `Application Support/Claude/vm_bundles` (~6 GB VM images), `Developer/CoreSimulator/Devices`.
- Four redundant Apple group-container excludes removed (shadowed by the `group.com.apple.*` / `com.apple.*` catch-alls); the container-metadata-plist exclude moved **above** the includes so the four included containers don't carry it.
- `Library/HTTPStorages` is **deliberately included** — excluding it would log users out of apps after a restore. Don't add it.

---

## Known open items (re-verified 2026-10-14)

- No warning when backing up secrets (Keychains, `.ssh`) to unencrypted drives — confirmed still true; flagged in the draft IT/security ticket.
- **MDM/FDA plan:** after company signing, give IT bundle ID + Team ID + `codesign -dr -` output for a PPPC profile granting `SystemPolicyAllFiles`. Child processes (zsh/rsync) inherit the app's grant. Test with the exported `.app`, not from Xcode (Xcode becomes the TCC-responsible process).
- **Code signing still `CODE_SIGN_STYLE = Automatic` with no `DEVELOPMENT_TEAM`**, personal bundle ID `com.mustafa.RsyncRettung`, no `.entitlements` file, `ENABLE_APP_SANDBOX = NO` (confirmed in `project.pbxproj`, 2026-09-22). Blocks any real MDM/company deployment — needs a company Developer ID, notarization, and a company bundle ID first. This is the main subject of the draft IT ticket (see above).
- Non-mirror restore space check demands full source size (false negatives on re-restores).
- `Library/…` exclude patterns are unanchored — since 2026-07-08 this is documented as intentional (matches container-internal caches), but it still also matches e.g. `Documents/myproject/Library/Caches`; root-level patterns are anchored now.
- `--skip-path` values are raw rsync patterns (folders named `foo*` would over-match).
- Tracked `xcuserdata` scheme plist (`xcschememanagement.plist`) is still git-tracked despite `xcuserdata/` being in `.gitignore` (the rule doesn't retroactively untrack) — needs `git rm --cached`. `.DS_Store` still missing from `.gitignore`.
- Restore truncation: a permission-denied write into an OS-managed container can still crash rsync's receiver; since 2026-10-14 the app *detects* it and reports "may have stopped early", but the root cause isn't prevented. Backup side has no equivalent detection (an early stop there exits 16 → generic "failed").
- Ideas: auto-scroll log, finish notification.
