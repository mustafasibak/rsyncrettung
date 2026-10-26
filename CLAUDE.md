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

## Shipped 2026-10-15

- **Unencrypted drive warning:** real backups check `volumeIsEncryptedKey` on the target (`driveIsEncrypted`); if false, a red sheet (`showUnencryptedWarning`) names keychains, SSH keys, browser logins, mail, explains Finder's Encrypt, and needs a checkbox. Its `onDismiss` then opens the cloud warning (`continueToCloudWarning`), since presenting a sheet while another is closing gets dropped. Verified: APFS volume encryption (`diskutil apfs encryptVolume`) and encrypted images report true, plain APFS false. Note: the internal FileVault Data volume reports false, irrelevant since only externals are checked.
- **Non-mirror restore space check moved after the pre-scan:** `performRestorePostScanSpaceCheck` runs on `XFER_KB` (needs XFER × 1.05) and terminates the run if short; the pre-flight check now only applies to mirror restores. If `XFER_KB` is missing (scan failed) there is no space check for non-mirror restores.
- **`--skip-path` anchored and escaped:** Swift passes `/<path>` (previously unanchored: deselecting `Music` skipped every `Music` folder at any depth) via `rsyncLiteralPattern`, which backslash-escapes `\ * ? [ ]` only when the name has a wildcard char (openrsync honours escapes only in wildcard patterns; verified `foo\*` skips `foo*` but not `fooX`).
- All `Library/...` patterns anchored (see Exclude lists).
- xcuserdata plist untracked, `.DS_Store` added to `.gitignore`.

## Shipped 2026-10-19 (new Mac restore test)

- **FDA check fixed:** primary canary is now `/Library/Application Support/com.apple.TCC/TCC.db` (exists on every Mac); the per-user `com.apple.TCC` folder was missing on a fresh Mac, so FDA was never detected. Tip for testers: launch from `/Applications`, not from the drive (App Translocation runs a quarantined copy from a random path, which the FDA grant doesn't match).
- **Drive disconnect → exit 31:** both watchdog loops check the drive every 1 s (backup: `$BACKUP_VOLUME`, not `$TARGET`, which a dry run never creates; restore: `$BACKUP_FOLDER`) and SIGKILL rsync + children; a non-zero rsync exit with the drive gone also maps to 31. Swift shows "drive was disconnected … continues where it stopped". Previously a yanked USB source drive froze the restore with no message (only the 300 s stall timeout would fire). Verified with a force-ejected sparse image: 31 instantly, no orphans (without the fix a disk image gives exit 1 → "failed (code 1)").
- **Cancel trap hardened:** TERM, wait up to 3 s, then `force_stop_rsync` (KILL children + rsync), exit 20. Verified: 20 in ~1 s, no orphans.
- Volume watcher no longer switches `selectedDrive`/`restoreSelectedDrive` while `isRunning`/`isPreparing`.
- **Mirror self-protection:** restore passes `--skip-path=/<relative app path>/` when `Bundle.main.bundlePath` is inside the home folder (app on Desktop/Downloads/`~/Applications` would otherwise be deleted by mirror restore). Restore excludes `/Desktop/RsyncRettung_restore_errors.log`, backup excludes `/rsync_errors.log`: before, mirror mode deleted the log being written (fd keeps writing to an unlinked file, Swift then found no log → skipped-files/early-stop detection silently blind), and an old restore log inside a backup could overwrite the live one in any mode. openrsync verified: excluded receiver paths are neither deleted nor overwritten under `--delete`. Dry-run mirror restore vs. a near-empty fake backup: 42,139 `deleting` lines, none for the log or a skipped folder.

## Shipped 2026-08-12 → 2026-09-22 (committed 2026-10-14 as `27ac2ff`)


- **Full Disk Access pre-flight check — implemented AND wired in.** `hasFullDiskAccess()` / `checkFullDiskAccess(then:)` (~`ContentView.swift:2021`) check readability of `/Library/Application Support/com.apple.TCC/TCC.db`, falling back to `~/Library/Application Support/com.apple.TCC` (since 2026-10-19: the per-user folder can be missing, which blocked FDA on a fresh Mac; still — deliberately not a stat check, since TCC only gates actual reads). `checkFullDiskAccess` is called from `startBackup()` (~line 976, gates `proceedWithBackup`/cloud warning) and from the restore space-check flow (~line 1260, gates `proceedWithRestore`) — shows a warning sheet if FDA is missing (since 2026-10-14: refers the user to IT, blocks real runs, dry runs only). This resolves [[project_fda_diagnosis_aug7]] and the old "No Full Disk Access check" open item below.
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
  ├─ dryRunMode  → proceedWithBackup() directly (skips all warning sheets)
  └─ else        → [showUnencryptedWarning if drive unencrypted] → showCloudWarning sheet → proceedWithBackup()
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
- Root-level patterns are **anchored**: `/.Trash*`, `/Nextcloud*` (unanchored they also hit e.g. `Documents/Nextcloud Notizen`). Since 2026-10-15 all `Library/...` excludes/includes are anchored too (`/Library/...`); caches inside the included containers are covered by explicit `/Library/Containers/*/Data/Library/Caches` and `/Library/Group Containers/*/Library/Caches`. Verified by diffing a full dry-run file list old vs new: the only change was a nested `Desktop/.../Library` copy now being backed up.
- **Office fix:** the blanket `UBF8T346G9.Office/` exclude is gone — it would silently drop classic-Outlook mailboxes (`…/Outlook/Outlook 15 Profiles`) and user templates on colleagues' Macs. Only `SolutionPackages`, `FontCache`, `ComRPC32` are excluded now.
- **Restore fix:** `iCloud Drive*` → exact `/iCloud Drive/` (the old pattern also blocked restoring a real folder like `iCloud Drive (Archiv)`).
- **New excludes** (post-FDA the TCC-protected system junk started flowing in, seen re-transferring every run): `Library/Trial`, `DuetExpertCenter`, `IntelligencePlatform`, `com.apple.aiml.instrumentation`, `Weather`, `Suggestions`, `Application Support/Knowledge`, `DifferentialPrivacy`, `Application Support/CloudDocs`, `Application Support/com.apple.wallpaper/aerials` (457 MB re-downloadable videos; `Store/` with the settings stays in).
- **New "Misc." category** for case-specific entries few Macs have: `Application Support/Claude/vm_bundles` (~6 GB VM images), `Developer/CoreSimulator/Devices`.
- Four redundant Apple group-container excludes removed (shadowed by the `group.com.apple.*` / `com.apple.*` catch-alls); the container-metadata-plist exclude moved **above** the includes so the four included containers don't carry it.
- `Library/HTTPStorages` is **deliberately included** — excluding it would log users out of apps after a restore. Don't add it.

---

## Known open items (re-verified 2026-10-14)

- **MDM/FDA plan:** after company signing, give IT bundle ID + Team ID + `codesign -dr -` output for a PPPC profile granting `SystemPolicyAllFiles`. Child processes (zsh/rsync) inherit the app's grant. Test with the exported `.app`, not from Xcode (Xcode becomes the TCC-responsible process).
- **Code signing still `CODE_SIGN_STYLE = Automatic` with no `DEVELOPMENT_TEAM`**, personal bundle ID `com.mustafa.RsyncRettung`, no `.entitlements` file, `ENABLE_APP_SANDBOX = NO` (confirmed in `project.pbxproj`, 2026-09-22). Blocks any real MDM/company deployment — needs a company Developer ID, notarization, and a company bundle ID first. This is the main subject of the draft IT ticket (see above).
- Restore truncation: mitigated since 2026-10-21 by auto-continue (see "Shipped 2026-10-21"). Still falls back to "may have stopped early" when the receiver crashes twice without an identifiable path. Not yet tested against the real Office container crash, only against `chflags uchg` reproductions.

## Shipped 2026-10-21

- **Restore auto-continue after a receiver crash:** openrsync's receiver dies outright when macOS refuses a write (reproduced with `chflags uchg` on a target dir/file: `mkstempat ... Operation not permitted` or `move_file ... Operation not permitted`, then `rsync_receiver` / `unexpected end of file`, exit 1). `rsync_restore.zsh` now loops: on a real run with non-zero exit and `unexpected end of file`, `refused_path_from_log` takes the first path from the receiver PID's error lines (temp names `.name.XXXXXXXXXX` mapped back, must exist in backup or target), adds an anchored, escaped `--exclude=/<path>` and reruns rsync. Skips the file first; a second failure in the same parent dir (≥3 levels deep, so never `Documents` or `Library/Preferences`) skips the dir. No retry cap (each restart excludes a new path); stops on a repeated path. A crash with no identifiable path gets one blind restart (`BLIND_RETRY_USED`, "⚠️ The copy process stopped unexpectedly. Restarting…"); a second one stops (early-stop message). Leftover temp files from failed renames (`move_file` lines) are removed. Earlier attempts' logs (crash lines stripped) plus `<path>: restore continued without it (...)` lines are prepended to the error log; `loadSkippedFiles` matches that phrase. Any skip turns exit 0 into 23 (warnings flow). Verified: locked Office-like folder → later `Library/Preferences`, `Music`, `Pictures/Ördner mit Umlaut` restored, exit 23; locked files directly in `Documents` → only those files skipped; mirror mode, dry run, clean run unchanged; Cancel → 20, no orphans; killed receiver once → blind restart, exit 0; twice → 16 + early-stop; 25 crashing locked files → all 25 skipped, rest restored.
- **Restore progress after skips:** per skip the script emits `RESTORE_SKIPPED=<path>` (dirs end in `/`, filtered from the log) and a ⚠️ line; at the end a ⚠️ summary lists the skipped items (files under a later skipped folder are folded into it). Swift `dropSkippedRestorePath` moves the path's bytes (still in `restoreXferSizeByPath` or already credited in `restoreCreditedSizes`) into `restoreSkippedKB`, which counts as done in `effectiveRestoreDoneKB` (`max(du delta, realDone + skipped)`); the total stays, so the bar never moves back and hits 100 % with the last real file, while the GB line subtracts skipped bytes from both numbers. (First version shrank the total and lowered the floor: the bar jumped back on the test Mac when the skipped file was most of the run.) Floor is raised to the current value before any skip or un-credit. It is re-applied from `restoreSkippedPaths` when the size map loads late. `creditRestoreFiles` un-credits a path that rsync lists again after a restart (files the crashed receiver never wrote), so it's credited once really written. Matching uses `restorePathMatchKey` because the sentinel has the real UTF-8 name while rsync output has the escaped form (`Ö` → raw byte + `\#226`): runs of non-ASCII / `\#ooo` collapse to `?`. Restore log lines starting with ⚠️ are yellow (`.warning`); path-bearing script lines must start with ⚠️ so the file-line heuristic ignores them. Verified by replaying crash runs through the Swift functions (monotone, ends at 100 %), and on the test Mac 2026-10-22: locked `names.csv` file → crash, restart, skip, summary, warnings banner, no orphans; a locked folder or locked small files did not crash openrsync there (plain exit 23).
- **Restore skipped display:** the restore bar is now `SegmentedProgressBar` too (new `skippedFraction` param, orange segment after the accent one); percentage label (`restorePercentLabel`) counts only written bytes (bar total minus orange), so a run with skips ends below 100 % as "N% restored" (rounded down); GB line appends `skipped: <size>`; restore GB line and backup new/changed pair use one unit per line via `sizeString(fromKB:scaleKB:)` (MB when the run is under 1 GB); `restoreSkippedList` shows up to 3 skipped paths in orange under the GB line (running and finished).
- **Quit stops the run:** `.onReceive(NSApplication.willTerminateNotification)` SIGTERMs the running script (same trap as Cancel). Before, Cmd+Q left zsh/rsync running with no window.
- **Refused files without a crash (exit 23):** openrsync often skips a refused write by itself (locked folder: `mkstempat ... Operation not permitted`, no receiver crash). It then **still sets the backup's mtime on the old, unreplaced file**, so it looks identical by size and mtime and later runs skip it forever. `unwritten_files_from_log` (restore script, real runs with exit 23) takes every file named in `Operation not permitted`/`Permission denied` lines (`path_from_error`, shared with `refused_path_from_log`) and compares content with `cmp -s`; differing or missing files get `RESTORE_SKIPPED=` and join the ⚠️ summary, so bar/percentage/GB line count them as skipped instead of restored. Files with identical content (e.g. only touched) are correctly not reported. The backup script has no such check (refusals on external drives are rare).
- **Backup skipped display (same as restore):** on exit 23/24 (real runs) `rsync_swift.zsh` runs `unsaved_files_from_log` (own copy of `path_from_error`, strips the `$USER_FOLDER/` prefix that sender read errors carry; content compare with `cmp -s` against `$TARGET`), emits `BACKUP_SKIPPED=<bytes> <relpath>` per file and a ⚠️ summary (max 20 lines). Swift `dropSkippedBackupPath` moves bytes found in `xferSizeByPath`/`backupCreditedSizes` into `backupSkippedKB`; **unreadable files are missing from the pre-scan transfer list** (openrsync's dry run drops them but counts them in `Total file size`), so before this they showed as striped "already on the drive": their size from the sentinel goes to `backupSkippedOutsideKB`, which is subtracted from `backupPreExistingKB` and added to the bar fill. Orange segment = both; label `N% backed up` (rounded down) when anything was skipped; GB line subtracts skipped and appends `skipped:`; `skippedList(_:reason:)` is shared by both tabs. Backup ⚠️ log lines are yellow. `restorePathMatchKey` renamed `pathMatchKey`. Verified by replaying a real second backup (one changed + one new unreadable file) through the Swift code: 81.8 % orange, 18 % backed up, striped only the truly unchanged files.
- **Always dark, resizable:** `RsyncRettungApp.init` sets `NSApplication.shared.appearance = .darkAqua` (all windows and sheets); window uses `.defaultSize(640, 860)` + `.windowResizability(.contentMinSize)`; content has `minWidth 640` but **no fixed min height**, so the window's minimum follows the content and grows when a finished run adds banner/bar/skipped list (a fixed 820 min made SwiftUI push the title and the restore toggles past the window edges, verified by screenshot). The log takes extra height (`minHeight 200/140, maxHeight .infinity`).
- `appendLog` writes to `finishingTab ?? activeTab`; both `group.notify` completions set `finishingTab` (with `defer` reset), since Cancel re-enables the tab picker before the completion runs and "Backup cancelled by user" landed in the restore log.
- Empty states blank: backup folder picker shows nothing (was "No folders found on drive") and the idle backup tab no longer shows a 0 % bar, speed, sizes and ETA (only while `isRunning`).
- Warning sheets: fixed heights became `.frame(width: W).frame(minHeight: H)` and checkbox/caption labels got `.fixedSize(horizontal: false, vertical: true)`; the restore mirror checkbox text was cut off at "from…" (verified fixed by screenshot, FDA sheet too).
- Screenshot testing: build a variant with injected `@State` defaults into a separate derived data dir, launch with `--args -ApplePersistenceIgnoreState YES` (macOS otherwise restores the last tab), find the window ID via `CGWindowListCopyWindowInfo` and `screencapture -l<id>`. Never `defaults delete` the app domain: it holds the learned drive speeds.
- `loadSkippedFiles` drops duplicate log lines (openrsync repeats some renameat/move_file errors).
- Early-stop message now says to deselect the folder named in the error log instead of "run the restore again" (rerunning hits the same folder).
- Ideas: auto-scroll log, finish notification.
