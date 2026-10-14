import SwiftUI
import AppKit
import CoreServices

enum AppTab { case backup, restore }
enum FinishState { case success, warnings, failed, cancelled }

enum LogType {
    case info, success, warning, error, highlight
}

struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    let type: LogType
}

// Kernel-driven (FSEvents), not polling: the OS notifies us only when
// something actually changes under `path`, recursively, coalesced into at
// most one callback per `latency` seconds so e.g. emptying the Trash doesn't
// fire thousands of times. A plain kqueue watch (as used for the /Volumes
// hotplug watcher) only sees changes to a directory's own immediate entries,
// not its subtree, so it can't catch a delete happening anywhere on a volume.
final class DriveSpaceWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(path: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.stream = nil
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { (_, info, _, _, _, _) in
            guard let info else { return }
            Unmanaged<DriveSpaceWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
        }
    }
}

struct RestoreTreeItem: Identifiable {
    let id = UUID()
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let depth: Int
}

struct SegmentedProgressBar: View {
    var preFraction: Double
    var totalFraction: Double

    var body: some View {
        GeometryReader { geo in
            let pre = min(1.0, max(0.0, preFraction))
            let new = min(1.0 - pre, max(0.0, totalFraction - pre))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay(
                            Canvas { context, size in
                                var x: CGFloat = -size.height
                                while x < size.width {
                                    var p = Path()
                                    p.move(to: CGPoint(x: x, y: size.height))
                                    p.addLine(to: CGPoint(x: x + size.height, y: 0))
                                    context.stroke(p, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
                                    x += 5
                                }
                            }
                        )
                        .frame(width: geo.size.width * pre)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * new)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 6)
    }
}

struct ContentView: View {

    // MARK: - Shared State
    @State private var drives: [String] = []
    @State private var backupLogEntries: [LogEntry] = []
    @State private var restoreLogEntries: [LogEntry] = []
    @State private var isRunning = false
    @State private var isPreparing = false
    @State private var process: Process?
    @State private var skippedFiles: [String] = []
    @State private var totalKB: Int64 = 1
    @State private var copiedKB: Int64 = 0
    @State private var targetPath: String = ""
    @State private var backupErrorLogPath: String = ""
    @State private var progressTimer: Timer?
    @State private var userCancelled = false
    @State private var lastCopiedKB: Int64 = 0
    @State private var lastEffectiveBackupDoneKB: Int64 = 0
    @State private var lastSampleTime: Date?
    @State private var speedKBps: Double = 0
    @State private var longSpeedKBps: Double = 0
    @State private var spaceCheckMessage: String = ""
    @State private var backupPendingLogEntries: [LogEntry] = []
    @State private var restorePendingLogEntries: [LogEntry] = []
    @State private var logFlushTimer: Timer?
    @State private var dryRunStats: [String] = []
    @State private var backupPinnedLogCount: Int = 0
    @State private var restorePinnedLogCount: Int = 0
    @State private var isScanning = false
    @State private var scanCompleted = false
    @State private var rawSourceKB: Int64 = 0
    @State private var rawFileCount: Int = 0
    @State private var stopWatcher: (() -> Void)?
    @State private var activeTab: AppTab = .backup
    @State private var showFDAWarning = false
    @State private var fdaWarningAcknowledged = false
    @State private var pendingFDAContinuation: (() -> Void)? = nil

    // MARK: - Backup State
    @State private var selectedDrive: String = ""
    @State private var driveFreeSpaceMessage: String = ""
    @State private var macFreeSpaceMessage: String = ""
    @State private var driveSpaceWatcher: DriveSpaceWatcher? = nil
    @State private var showCloudWarning = false
    @State private var cloudWarningAcknowledged = false
    @State private var showAdvancedSettings = false
    @State private var mirrorMode = false
    @State private var includeTrash = false
    @State private var dryRunMode = false
    @State private var showMirrorWarning = false
    @State private var mirrorWarningAcknowledged = false
    @State private var xferTotalKB: Int64 = 0
    @State private var xferSizeByPath: [String: Int64] = [:]
    @State private var xferSizeMapLoaded = false
    @State private var backupUncreditedFiles: [String] = []
    @State private var backupPendingFile: String? = nil
    @State private var backupRealDoneBytes: Int64 = 0
    @State private var baselineTargetKB: Int64 = 0
    @State private var backupStartTime: Date? = nil
    @State private var backupDoneFloorKB: Int64 = 0
    @State private var displayedBackupETA: Double? = nil

    // MARK: - Restore State
    @State private var restoreSelectedDrive: String = ""
    @State private var backupFolders: [String] = []
    @State private var selectedBackupFolder: String = ""
    @State private var restoreDryRunMode = false
    @State private var restoreMirrorMode = false
    @State private var showRestoreMirrorWarning = false
    @State private var restoreMirrorWarningAcknowledged = false
    @State private var showRestoreInUseWarning = false
    @State private var restoreInUseAcknowledged = false
    @State private var restoreInUseHomeKB: Int64 = 0
    @State private var pendingRestoreInUseContinuation: (() -> Void)? = nil
    @State private var pendingRestorePath: String = ""
    @State private var restoreTreeItems: [RestoreTreeItem] = []
    @State private var expandedRestorePaths: Set<String> = []
    @State private var excludedRestorePaths: Set<String> = []
    @State private var homeFolderKB: Int64 = 0
    @State private var homeFolderScopedKB: Int64 = 0
    @State private var dryRunToTransferByFolder: [String: Int] = [:]
    @State private var dryRunToDeleteByFolder: [String: Int] = [:]
    @State private var dryRunToTransferSizeByFolder: [String: Int64] = [:]
    @State private var dryRunToTransferBySubfolder: [String: Int] = [:]
    @State private var dryRunToTransferSizeBySubfolder: [String: Int64] = [:]
    @State private var restoreFilesTotal: Int = 0
    @State private var restoreXferSizeByPath: [String: Int64] = [:]
    @State private var restoreXferSizeMapLoaded = false
    @State private var restoreUncreditedFiles: [String] = []
    @State private var restorePendingFile: String? = nil
    @State private var restoreRealDoneBytes: Int64 = 0
    @State private var restoreCopiedKB: Int64 = 0
    @State private var restoreProgressTimer: Timer? = nil
    @State private var restoreSpeedKBps: Double = 0
    @State private var longRestoreSpeedKBps: Double = 0
    @State private var restoreLastCopiedKB: Int64 = 0
    @State private var lastEffectiveRestoreDoneKB: Int64 = 0
    @State private var restoreLastSampleTime: Date? = nil
    @State private var restoreXferTotalKB: Int64 = 0
    @State private var restoreBaselineKB: Int64 = 0
    @State private var restoreStartTime: Date? = nil
    @State private var restoreDoneFloorKB: Int64 = 0
    @State private var displayedRestoreETA: Double? = nil

    // MARK: - Finish State
    @State private var backupFinishState: FinishState? = nil
    @State private var restoreFinishState: FinishState? = nil

    // MARK: - Computed

    func appendLog(_ message: String, type: LogType = .info) {
        if activeTab == .backup {
            backupLogEntries.append(LogEntry(message: message, type: type))
        } else {
            restoreLogEntries.append(LogEntry(message: message, type: type))
        }
    }

    // Bytes done this run = sum of the real sizes of files rsync has finished
    // (sizes from the pre-scan list; a file is credited when the next file
    // line appears), with the du delta covering the in-flight file's bytes.
    var effectiveBackupDoneKB: Int64 {
        let duDelta = max(0, copiedKB - baselineTargetKB)
        let done = max(duDelta, backupRealDoneBytes / 1024)
        return max(backupDoneFloorKB, xferTotalKB > 0 ? min(xferTotalKB, done) : done)
    }

    var effectiveRestoreDoneKB: Int64 {
        let duDelta = max(0, restoreCopiedKB - restoreBaselineKB)
        let done = max(duDelta, restoreRealDoneBytes / 1024)
        return max(restoreDoneFloorKB, restoreXferTotalKB > 0 ? min(restoreXferTotalKB, done) : done)
    }

    // Once the scan reports both sizes, the bar spans the full source size:
    // it starts pre-filled with what's already on the drive (totalKB − xferTotalKB)
    // and only the new/changed data grows from there.
    var backupPreExistingKB: Int64 {
        xferTotalKB > 0 ? max(0, totalKB - xferTotalKB) : 0
    }

    var backupPreFraction: Double {
        guard xferTotalKB > 0, totalKB > 0 else { return 0 }
        return min(1.0, Double(backupPreExistingKB) / Double(totalKB))
    }

    var progress: Double {
        if xferTotalKB > 0, totalKB > 0 {
            let done = min(totalKB, backupPreExistingKB + effectiveBackupDoneKB)
            return Double(done) / Double(totalKB)
        }
        guard totalKB > 0 else { return 0 }
        return min(1.0, Double(copiedKB) / Double(totalKB))
    }

    var restoreProgress: Double {
        if restoreXferTotalKB > 0 {
            return min(1.0, Double(effectiveRestoreDoneKB) / Double(restoreXferTotalKB))
        }
        guard totalKB > 0 else { return 0 }
        return min(1.0, Double(restoreCopiedKB) / Double(totalKB))
    }

    var remainingKB: Int64 {
        xferTotalKB > 0 ? max(0, xferTotalKB - effectiveBackupDoneKB) : max(0, totalKB - copiedKB)
    }

    var etaString: String {
        if let s = displayedBackupETA { return "ETA: \(formatDuration(seconds: s))" }
        return "ETA: calculating…"
    }

    var restoreRemainingKB: Int64 {
        restoreXferTotalKB > 0 ? max(0, restoreXferTotalKB - effectiveRestoreDoneKB) : max(0, totalKB - restoreCopiedKB)
    }

    var restoreETAString: String {
        if let s = displayedRestoreETA { return "ETA: \(formatDuration(seconds: s))" }
        return "ETA: calculating…"
    }

    var backupGBLine: String {
        if xferTotalKB > 0 {
            let done = min(totalKB, backupPreExistingKB + effectiveBackupDoneKB)
            return "\(gbString(fromKB: done)) / \(gbString(fromKB: totalKB))  ·  new/changed: \(gbString(fromKB: effectiveBackupDoneKB)) / \(gbString(fromKB: xferTotalKB))"
        }
        return "\(gbString(fromKB: copiedKB)) / \(gbString(fromKB: totalKB))"
    }

    var restoreGBLine: String {
        if restoreXferTotalKB > 0 {
            return "\(gbString(fromKB: effectiveRestoreDoneKB)) / \(gbString(fromKB: restoreXferTotalKB)) to restore"
        }
        return "\(gbString(fromKB: restoreCopiedKB)) / \(gbString(fromKB: totalKB))"
    }

    var logAttributedString: AttributedString {
        let entries = activeTab == .backup ? backupLogEntries : restoreLogEntries
        var result = AttributedString()
        for (i, entry) in entries.enumerated() {
            var part = AttributedString(entry.message)
            part.foregroundColor = color(for: entry.type)
            result += part
            if i < entries.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text(activeTab == .backup ? "User Folder Backup" : "User Folder Restore")
                .font(.largeTitle)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("", selection: $activeTab) {
                    Text("Backup").tag(AppTab.backup)
                    Text("Restore (Beta)").tag(AppTab.restore)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .disabled(isRunning || isPreparing)
            }

            if activeTab == .backup {
                backupControlsView
            } else {
                restoreControlsView
            }

            Divider()

            if !spaceCheckMessage.isEmpty {
                Text(spaceCheckMessage)
                    .foregroundColor(
                        spaceCheckMessage.hasPrefix("Not enough") || spaceCheckMessage.hasPrefix("Insufficient") ? .red
                            : spaceCheckMessage.hasPrefix("Note:") ? .orange
                            : .green
                    )
                    .font(.system(.footnote, design: .monospaced))
            }

            Text("Log Output:")

            ScrollView {
                Text(logAttributedString)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: activeTab == .backup ? 260 : 200)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            if activeTab == .backup {
                backupProgressView
            } else {
                restoreProgressView
            }

            HStack {
                Spacer()
                if activeTab == .backup {
                    Button("Advanced Settings") { showAdvancedSettings = true }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $restoreDryRunMode) {
                            VStack(alignment: .leading) {
                                Text("Dry Run")
                                Text("Preview what would be restored without copying any files")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox).disabled(isRunning)
                        Toggle(isOn: $restoreMirrorMode) {
                            VStack(alignment: .leading) {
                                Text("Mirror Restore (--delete)")
                                Text("Also delete files in ~ not present in the backup")
                                    .font(.caption).foregroundColor(.orange)
                            }
                        }
                        .toggleStyle(.checkbox).disabled(isRunning)
                        .onChange(of: restoreMirrorMode) { _, newVal in
                            if newVal { restoreMirrorWarningAcknowledged = false; showRestoreMirrorWarning = true }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 820)

        // CLOUD WARNING
        .sheet(isPresented: $showCloudWarning, onDismiss: { cloudWarningAcknowledged = false }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Before you start")
                    .font(.title2).fontWeight(.semibold)
                Text("Data synced with cloud services can cause inaccuracies in the backup process. Please make sure you are logged out of all cloud services before proceeding (e.g. iCloud, Nextcloud, Adobe Creative Cloud)")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)
                Toggle(isOn: $cloudWarningAcknowledged) {
                    Text("I have logged myself out of all cloud services")
                }
                .toggleStyle(.checkbox)
                Spacer()
                HStack {
                    Button("Cancel") { showCloudWarning = false }
                    Spacer()
                    Button("Start Backup") {
                        showCloudWarning = false
                        proceedWithBackup()
                    }
                    .disabled(!cloudWarningAcknowledged)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 420, height: 240)
        }

        // FULL DISK ACCESS WARNING
        .sheet(isPresented: $showFDAWarning, onDismiss: { fdaWarningAcknowledged = false; pendingFDAContinuation = nil }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Full Disk Access Not Detected")
                    .font(.title2).fontWeight(.semibold)
                Text("RsyncRettung doesn't have Full Disk Access. Without it, macOS blocks access to Mail, Safari, Messages, Notes and other protected folders and skips them with no error. The run can still finish and look successful even though that data was never copied.\n\nOn company Macs this permission is granted automatically by IT. Please contact IT support. A real backup or restore can't start until access is granted.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)
                if fdaPendingIsDryRun {
                    Toggle(isOn: $fdaWarningAcknowledged) {
                        Text("Run the dry run anyway (results will be incomplete)")
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
                HStack {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                    Button("Cancel") {
                        showFDAWarning = false
                        pendingFDAContinuation = nil
                    }
                    if fdaPendingIsDryRun {
                        Button("Continue Dry Run") {
                            showFDAWarning = false
                            let proceed = pendingFDAContinuation
                            pendingFDAContinuation = nil
                            proceed?()
                        }
                        .disabled(!fdaWarningAcknowledged)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(28)
            .frame(width: 500, height: 340)
        }

        // ADVANCED SETTINGS
        .sheet(isPresented: $showAdvancedSettings) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Advanced Settings").font(.title2)
                Toggle(isOn: $mirrorMode) {
                    VStack(alignment: .leading) {
                        Text("Mirror Backup (--delete)")
                        Text("Deletes files on target that no longer exist on source")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .onChange(of: mirrorMode) { _, newVal in
                    if newVal { mirrorWarningAcknowledged = false; showMirrorWarning = true }
                }
                Toggle(isOn: $includeTrash) {
                    VStack(alignment: .leading) {
                        Text("Include Trash")
                        Text("Include user's Trash folder in backup")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $dryRunMode) {
                    VStack(alignment: .leading) {
                        Text("Dry Run (--dry-run)")
                        Text("Preview what would be transferred without copying any files")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("Close") { showAdvancedSettings = false }
            }
            .padding(24)
            .frame(width: 400, height: 320)
        }

        // MIRROR WARNING
        .sheet(isPresented: $showMirrorWarning, onDismiss: { mirrorWarningAcknowledged = false }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Mirror Mode is Enabled")
                    .font(.title2).fontWeight(.semibold)
                Text("Mirror mode will delete files on the backup drive that no longer exist on this Mac. This cannot be undone. Make sure you intentionally enabled this option before continuing.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)
                Toggle(isOn: $mirrorWarningAcknowledged) {
                    Text("I understand that files may be permanently deleted from the backup drive")
                }
                .toggleStyle(.checkbox)
                Spacer()
                HStack {
                    Button("Turn Off Mirror Mode") {
                        mirrorMode = false
                        showMirrorWarning = false
                    }
                    Spacer()
                    Button("Keep Mirror Mode On") {
                        showMirrorWarning = false
                    }
                    .disabled(!mirrorWarningAcknowledged)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 420, height: 260)
        }

        // RESTORE MIRROR WARNING
        .sheet(isPresented: $showRestoreMirrorWarning, onDismiss: { restoreMirrorWarningAcknowledged = false }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Mirror Restore Will Delete Files")
                    .font(.title2).fontWeight(.semibold)
                Text("Mirror mode deletes everything in your home folder (~/) that is not in the backup, including files you created on this Mac after the last backup was made.\n\nThis cannot be undone.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)
                Toggle(isOn: $restoreMirrorWarningAcknowledged) {
                    Text("I understand that files may be permanently deleted from my home folder")
                }
                .toggleStyle(.checkbox)
                Spacer()
                HStack {
                    Button("Turn Off Mirror Mode") {
                        restoreMirrorMode = false
                        showRestoreMirrorWarning = false
                    }
                    Spacer()
                    Button("Keep Mirror Mode On") {
                        showRestoreMirrorWarning = false
                    }
                    .disabled(!restoreMirrorWarningAcknowledged)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(24)
            .frame(width: 420, height: 280)
        }

        // RESTORE ONTO A MAC IN USE
        .sheet(isPresented: $showRestoreInUseWarning, onDismiss: { restoreInUseAcknowledged = false; pendingRestoreInUseContinuation = nil }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("This Mac Is Already in Use")
                    .font(.title2).fontWeight(.semibold)
                Text("Your home folder already contains \(gbString(fromKB: restoreInUseHomeKB)). Restore is meant for a new or empty Mac.\n\nFiles that exist both here and in the backup will be replaced by the backup version, even if the version on this Mac is newer. Work done on this Mac after the backup was made can be lost.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)
                Toggle(isOn: $restoreInUseAcknowledged) {
                    Text("I understand newer files on this Mac may be overwritten")
                }
                .toggleStyle(.checkbox)
                Spacer()
                HStack {
                    Button("Cancel") {
                        showRestoreInUseWarning = false
                        pendingRestoreInUseContinuation = nil
                    }
                    Spacer()
                    Button("Restore Anyway") {
                        showRestoreInUseWarning = false
                        let proceed = pendingRestoreInUseContinuation
                        pendingRestoreInUseContinuation = nil
                        proceed?()
                    }
                    .disabled(!restoreInUseAcknowledged)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(24)
            .frame(width: 460, height: 320)
        }

        .onAppear {
            drives = detectDrives()
            if selectedDrive.isEmpty, let first = drives.first {
                selectedDrive = first
            }
            if restoreSelectedDrive.isEmpty, let first = drives.first {
                restoreSelectedDrive = first
                backupFolders = detectBackupFolders(onDrive: first)
                selectedBackupFolder = preferredBackupFolder(from: backupFolders)
                loadRestoreTree(forFolder: selectedBackupFolder)
            }
            startVolumeWatcher()
        }
        .onDisappear {
            stopVolumeWatcher()
        }
    }

    // MARK: - Tab Content Views

    @ViewBuilder
    var backupControlsView: some View {
        Picker("Select Backup Drive:", selection: $selectedDrive) {
            ForEach(drives, id: \.self) { Text($0).tag($0) }
        }
        .frame(width: 300)
        .onChange(of: selectedDrive) { _, _ in updateDriveFreeSpaceMessage() }

        if !driveFreeSpaceMessage.isEmpty {
            Text(driveFreeSpaceMessage)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.secondary)
        }

        HStack {
            Button("Start Backup") { startBackup() }
                .disabled(selectedDrive.isEmpty || isRunning || isPreparing)
            Button("Cancel") {
                userCancelled = true
                process?.terminate()
                isRunning = false
                stopProgressTimer()
            }
            .disabled(!isRunning)
        }
    }

    @ViewBuilder
    var restoreControlsView: some View {
        Picker("Select Drive with Backup:", selection: $restoreSelectedDrive) {
            ForEach(drives, id: \.self) { Text($0).tag($0) }
        }
        .frame(width: 300)
        .onChange(of: restoreSelectedDrive) { _, newValue in
            backupFolders = detectBackupFolders(onDrive: newValue)
            selectedBackupFolder = preferredBackupFolder(from: backupFolders)
            loadRestoreTree(forFolder: selectedBackupFolder)
        }

        Text(macFreeSpaceMessage)
            .font(.system(.footnote, design: .monospaced))
            .foregroundColor(.secondary)
            .onAppear { refreshMacFreeSpace() }

        Picker("Select Backup Folder:", selection: $selectedBackupFolder) {
            if backupFolders.isEmpty {
                Text("No folders found on drive").tag("")
            } else {
                ForEach(backupFolders, id: \.self) { Text($0).tag($0) }
            }
        }
        .frame(width: 300)
        .onChange(of: selectedBackupFolder) { _, newValue in
            loadRestoreTree(forFolder: newValue)
        }

        if !restoreTreeItems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Select what to restore:")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { excludedRestorePaths = [] }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.blue)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Button("None") {
                        excludedRestorePaths = Set(restoreTreeItems.filter { $0.depth == 0 }.map { $0.relativePath })
                    }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.blue)
                }
                .frame(maxWidth: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(restoreTreeItems) { item in
                            let excluded = isRestorePathExcluded(item.relativePath)
                            let parentExcluded = excluded && !excludedRestorePaths.contains(item.relativePath)
                            HStack(spacing: 4) {
                                if item.depth > 0 {
                                    Spacer().frame(width: CGFloat(item.depth * 16))
                                }
                                if item.isDirectory {
                                    Button { toggleRestoreExpand(item) } label: {
                                        Image(systemName: expandedRestorePaths.contains(item.relativePath) ? "chevron.down" : "chevron.right")
                                            .font(.caption2)
                                            .frame(width: 12)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Spacer().frame(width: 16)
                                }
                                Toggle(isOn: Binding(
                                    get: { !excluded },
                                    set: { include in
                                        if include {
                                            excludedRestorePaths.remove(item.relativePath)
                                        } else {
                                            excludedRestorePaths = excludedRestorePaths.filter {
                                                !$0.hasPrefix(item.relativePath + "/")
                                            }
                                            excludedRestorePaths.insert(item.relativePath)
                                        }
                                    }
                                )) {
                                    HStack(spacing: 4) {
                                        Image(systemName: item.isDirectory ? "folder" : "doc")
                                            .font(.caption2)
                                            .foregroundStyle(excluded ? .tertiary : .secondary)
                                        Text(item.name)
                                            .font(.system(.footnote, design: .monospaced))
                                            .foregroundStyle(excluded ? .tertiary : .primary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .disabled(parentExcluded)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
            }
        }

        HStack {
            Button("Start Restore") { startRestore() }
                .disabled(restoreSelectedDrive.isEmpty || selectedBackupFolder.isEmpty || isRunning || isPreparing)
            Button("Cancel") {
                userCancelled = true
                process?.terminate()
                isRunning = false
            }
            .disabled(!isRunning)
        }
    }

    @ViewBuilder
    var backupProgressView: some View {
        if let state = backupFinishState, !isRunning {
            finishBanner(state: state, dryRun: dryRunMode)
            if !dryRunMode {
                HStack(spacing: 10) {
                    SegmentedProgressBar(preFraction: backupPreFraction, totalFraction: progress).frame(maxWidth: 260)
                    Text("\(Int((progress * 100).rounded()))%").font(.system(.footnote, design: .monospaced))
                }
                Text(backupGBLine)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else if isScanning && isRunning {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text("Scanning files to transfer...")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else if dryRunMode && isRunning {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text("Dry run in progress. No files are being copied.")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                SegmentedProgressBar(preFraction: backupPreFraction, totalFraction: progress)
                    .frame(maxWidth: 260)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(.footnote, design: .monospaced))
                Text("Speed: \(speedString(fromKBps: speedKBps))")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(backupGBLine)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(etaString)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var restoreProgressView: some View {
        if let state = restoreFinishState, !isRunning {
            finishBanner(state: state, dryRun: restoreDryRunMode)
            if !restoreDryRunMode {
                HStack(spacing: 10) {
                    ProgressView(value: restoreProgress).frame(maxWidth: 260)
                    Text("\(Int((restoreProgress * 100).rounded()))%").font(.system(.footnote, design: .monospaced))
                }
                Text(restoreGBLine)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else if isScanning && isRunning {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text("Scanning files to restore...")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else if isRunning && restoreDryRunMode {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                Text("Dry (simulation) run in progress. No files are being copied.")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else if isRunning {
            HStack(spacing: 10) {
                ProgressView(value: restoreProgress)
                    .frame(maxWidth: 260)
                Text("\(Int((restoreProgress * 100).rounded()))%")
                    .font(.system(.footnote, design: .monospaced))
                Text("Speed: \(speedString(fromKBps: restoreSpeedKBps))")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(restoreGBLine)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(restoreETAString)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            HStack { }.frame(height: 20)
        }
    }

    // MARK: - Volume Watcher

    func startVolumeWatcher() {
        let fd = open("/Volumes", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler {
            let updated = detectDrives()
            DispatchQueue.main.async {
                drives = updated
                if !updated.contains(selectedDrive) { selectedDrive = updated.first ?? "" }
                if !updated.contains(restoreSelectedDrive) { restoreSelectedDrive = updated.first ?? "" }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        stopWatcher = { source.cancel() }
    }

    func stopVolumeWatcher() {
        stopWatcher?()
        stopWatcher = nil
    }

    // MARK: - Drive / Folder Detection

    func detectDrives() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return [] }
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        return items.filter { name in
            let url = URL(fileURLWithPath: "/Volumes/" + name)
            guard fm.isWritableFile(atPath: url.path),
                  let v = try? url.resourceValues(forKeys: keys) else { return false }
            return v.volumeIsInternal == false && v.volumeIsLocal == true && v.volumeIsRootFileSystem == false
        }
    }

    func detectBackupFolders(onDrive drive: String) -> [String] {
        let drivePath = "/Volumes/\(drive)"
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: drivePath) else { return [] }
        return items.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: "\(drivePath)/\(name)", isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    func preferredBackupFolder(from folders: [String]) -> String {
        let username = NSUserName()
        return folders.first(where: { $0 == username }) ?? folders.first ?? ""
    }

    func isDirectoryAtPath(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func loadRestoreTree(forFolder folder: String) {
        guard !folder.isEmpty else { restoreTreeItems = []; return }
        let basePath = "/Volumes/\(restoreSelectedDrive)/\(folder)"
        restoreTreeItems = makeTreeItems(basePath: basePath, relativePath: "", depth: 0)
        expandedRestorePaths = []
        excludedRestorePaths = []
    }

    func makeTreeItems(basePath: String, relativePath: String, depth: Int) -> [RestoreTreeItem] {
        let fullPath = relativePath.isEmpty ? basePath : "\(basePath)/\(relativePath)"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: fullPath) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { a, b in
                let aIsDir = isDirectoryAtPath("\(fullPath)/\(a)")
                let bIsDir = isDirectoryAtPath("\(fullPath)/\(b)")
                if aIsDir != bIsDir { return aIsDir }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { name in
                let rel = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                return RestoreTreeItem(name: name, relativePath: rel,
                                       isDirectory: isDirectoryAtPath("\(fullPath)/\(name)"),
                                       depth: depth)
            }
    }

    func toggleRestoreExpand(_ item: RestoreTreeItem) {
        let basePath = "/Volumes/\(restoreSelectedDrive)/\(selectedBackupFolder)"
        if expandedRestorePaths.contains(item.relativePath) {
            expandedRestorePaths.remove(item.relativePath)
            let prefix = item.relativePath + "/"
            restoreTreeItems.removeAll { $0.relativePath.hasPrefix(prefix) }
            expandedRestorePaths = expandedRestorePaths.filter { !$0.hasPrefix(prefix) }
        } else {
            expandedRestorePaths.insert(item.relativePath)
            let children = makeTreeItems(basePath: basePath, relativePath: item.relativePath, depth: item.depth + 1)
            if let idx = restoreTreeItems.firstIndex(where: { $0.id == item.id }) {
                restoreTreeItems.insert(contentsOf: children, at: idx + 1)
            }
        }
    }

    func isRestorePathExcluded(_ path: String) -> Bool {
        if excludedRestorePaths.contains(path) { return true }
        var parts = path.components(separatedBy: "/")
        parts.removeLast()
        while !parts.isEmpty {
            if excludedRestorePaths.contains(parts.joined(separator: "/")) { return true }
            parts.removeLast()
        }
        return false
    }

    // MARK: - Backup

    func startBackup() {
        guard bundledScriptURL() != nil else {
            appendLog("Script not found.", type: .error)
            return
        }
        userCancelled = false
        lastSampleTime = nil
        speedKBps = 0
        longSpeedKBps = 0
        targetPath = ""
        backupErrorLogPath = ""
        skippedFiles = []
        dryRunStats = []
        backupPinnedLogCount = 0
        isScanning = false
        scanCompleted = false
        rawSourceKB = 0
        rawFileCount = 0
        xferTotalKB = 0
        xferSizeByPath = [:]
        xferSizeMapLoaded = false
        backupUncreditedFiles = []
        backupPendingFile = nil
        backupRealDoneBytes = 0
        baselineTargetKB = 0
        backupStartTime = nil
        backupDoneFloorKB = 0
        displayedBackupETA = nil
        backupFinishState = nil
        spaceCheckMessage = ""
        stopProgressTimer()

        appendLog("Checking target drive...")
        let drivePath = "/Volumes/\(selectedDrive)"
        let username = NSUserName()
        let targetFolder = "\(drivePath)/\(username)"

        isPreparing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let currentTargetKB = Int64(self.duKB(targetFolder))
            DispatchQueue.main.async {
                self.isPreparing = false
                self.copiedKB = currentTargetKB
                self.lastCopiedKB = currentTargetKB
                self.lastEffectiveBackupDoneKB = 0
                self.baselineTargetKB = currentTargetKB
                self.totalKB = max(1, currentTargetKB)

                self.checkFullDiskAccess {
                    if self.dryRunMode {
                        self.proceedWithBackup()
                    } else {
                        self.showCloudWarning = true
                    }
                }
            }
        }
    }

    func proceedWithBackup() {
        guard let scriptURL = bundledScriptURL() else { return }

        appendLog("Backup process started (rsync)...", type: .success)
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        var args = [scriptURL.path, selectedDrive]
        if mirrorMode   { args.append("--delete") }
        if includeTrash { args.append("--include-trash") }
        if dryRunMode   { args.append("--dry-run") }
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let isDryRun = dryRunMode

        // Group tracks in-flight main-thread log/state updates AND the process
        // termination handler, so the completion logic (run on pipe EOF) never
        // reads a stale exit status or misses the final output chunk.
        let group = DispatchGroup()
        var capturedExitStatus: Int32 = 0

        // rsync output arrives in arbitrary chunks that can split a line (or a
        // multi-byte character) in half — parse only complete buffered lines,
        // keeping the tail until its newline (or EOF) arrives.
        var streamBuffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let isEOF = data.isEmpty
            if !isEOF { streamBuffer.append(data) }
            let cutoff: Data.Index? = isEOF
                ? streamBuffer.endIndex
                : streamBuffer.lastIndex(of: UInt8(ascii: "\n")).map { streamBuffer.index(after: $0) }

            if let cutoff, cutoff > streamBuffer.startIndex {
                let output = String(decoding: streamBuffer[streamBuffer.startIndex..<cutoff], as: UTF8.self)
                streamBuffer.removeSubrange(streamBuffer.startIndex..<cutoff)
                let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { String($0).trimmingCharacters(in: .newlines) }
                let newEntries = lines.filter { line in
                        !line.isEmpty &&
                        !line.hasPrefix("TOTAL_KB=") &&
                        !line.hasPrefix("RAW_SOURCE_KB=") &&
                        !line.hasPrefix("RAW_FILE_COUNT=") &&
                        !line.hasPrefix("XFER_KB=") &&
                        !line.hasPrefix("XFER_LIST=") &&
                        !line.hasPrefix("TARGET=") &&
                        !line.hasPrefix("ERROR_LOG=") &&
                        line != "SCAN_START" &&
                        line != "SCAN_END" &&
                        !line.hasPrefix("RUNNING_AS=") &&
                        !line.hasPrefix("PWD=")
                    }
                    .map { LogEntry(message: $0, type: .info) }
                var fileLines: [String] = []
                if !isDryRun {
                    for line in lines {
                        if let first = line.first, first.isLetter,
                           line.contains("/"), !line.hasSuffix("/"),
                           !line.hasPrefix("deleting "), !line.hasPrefix("*deleting ") {
                            fileLines.append(line)
                        }
                    }
                }
                group.enter()
                DispatchQueue.main.async {
                    self.backupPendingLogEntries.append(contentsOf: newEntries)
                    self.creditBackupFiles(fileLines)
                    self.handleScriptOutput(output)
                    group.leave()
                }
            }

            if isEOF {
                // Pipe EOF — clearing the handler prevents a retain cycle.
                handle.readabilityHandler = nil
                group.notify(queue: .main) {
                    self.isRunning = false
                    self.stopProgressTimer()
                    self.flushAndStopLogTimer()

                    if self.userCancelled {
                        self.backupFinishState = .cancelled
                        self.appendLog("Backup cancelled by user.", type: .warning)
                        return
                    }

                    if self.spaceCheckMessage.hasPrefix("Not enough") {
                        self.backupFinishState = .failed
                        return
                    }

                    if self.dryRunMode && !self.dryRunStats.isEmpty {
                        self.showDryRunSummary(label: "copy")
                    }

                    if !self.dryRunMode, [0, 23, 24].contains(capturedExitStatus),
                       let start = self.backupStartTime {
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed >= 10 {
                            self.recordSpeed(Double(self.effectiveBackupDoneKB) / elapsed, forDrive: self.selectedDrive)
                        }
                    }

                    switch capturedExitStatus {
                    case 0:
                        self.backupFinishState = .success
                        self.appendLog(
                            self.dryRunMode ? "Dry run complete." : "Backup completed successfully.",
                            type: self.dryRunMode ? .info : .success
                        )
                    case 23, 24:
                        let logFile = self.backupErrorLogPath.isEmpty ? "\(self.targetPath)/rsync_errors.log" : self.backupErrorLogPath
                        let skipped = self.loadSkippedFiles(logFile: logFile)
                        self.skippedFiles = skipped
                        if skipped.isEmpty {
                            self.backupFinishState = .success
                            self.appendLog(self.dryRunMode ? "Dry run complete." : "Backup complete. A few system protected files were skipped (normal).", type: .success)
                        } else {
                            self.backupFinishState = .warnings
                            self.appendLog(self.dryRunMode ? "Dry run complete with warnings." : "Backup completed with warnings.", type: .warning)
                            self.showSkippedFiles(skipped, limit: self.dryRunMode ? .max : 20, logPath: logFile)
                        }
                    case _ where !self.dryRunMode && capturedExitStatus != 30
                        && self.logShowsEarlyStop(self.backupErrorLogPath.isEmpty ? "\(self.targetPath)/rsync_errors.log" : self.backupErrorLogPath):
                        self.backupFinishState = .failed
                        self.appendLog("Backup stopped early: rsync's copy process crashed partway through, so the backup is incomplete. Start the backup again. It continues where it stopped.", type: .error)
                    case 30:
                        self.backupFinishState = .failed
                        self.appendLog("Backup stopped: no data moved for 5 minutes. A file didn't respond, most often a cloud placeholder (iCloud, Creative Cloud) waiting for a download. Pause cloud sync or download the files, then start the backup again. It continues where it stopped.", type: .error)
                    default:
                        self.backupFinishState = .failed
                        self.appendLog("Backup failed (code: \(capturedExitStatus)).", type: .error)
                    }
                }
            }
        }

        group.enter()
        process.terminationHandler = { proc in
            capturedExitStatus = proc.terminationStatus
            group.leave()
        }

        do {
            try process.run()
            isRunning = true
            backupPinnedLogCount = backupLogEntries.count
            startLogFlushTimer()
        } catch {
            process.terminationHandler = nil
            group.leave()
            pipe.fileHandleForReading.readabilityHandler = nil
            appendLog("Failed to start backup.", type: .error)
        }
    }

    // MARK: - Restore

    func startRestore() {
        guard bundledRestoreScriptURL() != nil else {
            appendLog("Restore script not found.", type: .error)
            return
        }
        guard !selectedBackupFolder.isEmpty else { return }

        // Keep the home size a prior dry-run measured (HOME_RAW_KB sentinel) so
        // the mirror space check can reuse it instead of re-running du.
        let priorHomeKB = homeFolderKB

        userCancelled = false
        lastSampleTime = nil
        speedKBps = 0
        longSpeedKBps = 0
        skippedFiles = []
        dryRunStats = []
        restorePinnedLogCount = 0
        restoreFinishState = nil
        spaceCheckMessage = ""
        rawSourceKB = 0
        rawFileCount = 0
        homeFolderKB = 0
        homeFolderScopedKB = 0
        dryRunToTransferByFolder = [:]
        dryRunToDeleteByFolder = [:]
        dryRunToTransferSizeByFolder = [:]
        dryRunToTransferBySubfolder = [:]
        dryRunToTransferSizeBySubfolder = [:]
        restoreFilesTotal = 0
        restoreXferSizeByPath = [:]
        restoreXferSizeMapLoaded = false
        restoreUncreditedFiles = []
        restorePendingFile = nil
        restoreRealDoneBytes = 0
        restoreCopiedKB = 0
        restoreSpeedKBps = 0
        longRestoreSpeedKBps = 0
        restoreLastCopiedKB = 0
        restoreLastSampleTime = nil
        restoreXferTotalKB = 0
        restoreBaselineKB = 0
        restoreStartTime = nil
        restoreDoneFloorKB = 0
        displayedRestoreETA = nil
        stopProgressTimer()
        stopRestoreProgressTimer()

        let backupFolderPath = "/Volumes/\(restoreSelectedDrive)/\(selectedBackupFolder)"
        appendLog("Checking backup source...")

        guard FileManager.default.fileExists(atPath: backupFolderPath) else {
            appendLog("Backup folder not found: \(backupFolderPath)", type: .error)
            return
        }

        // Measure actual bytes to restore, subtracting any deselected folders.
        // du can take a while on a big backup drive, so run it off the main thread.
        let excludedPaths = excludedRestorePaths
        let needsHomeSize = !restoreDryRunMode && priorHomeKB <= 0
        isPreparing = true
        DispatchQueue.global(qos: .userInitiated).async {
            var sourceKB = Int64(self.duKB(backupFolderPath))
            for relPath in excludedPaths {
                sourceKB = max(0, sourceKB - Int64(self.duKB("\(backupFolderPath)/\(relPath)")))
            }
            let measuredHomeKB = needsHomeSize ? Int64(self.duKB(NSHomeDirectory())) : priorHomeKB
            DispatchQueue.main.async {
                self.isPreparing = false
                self.finishRestorePreparation(backupFolderPath: backupFolderPath,
                                              sourceKB: sourceKB,
                                              currentDestKB: measuredHomeKB)
            }
        }
    }

    func finishRestorePreparation(backupFolderPath: String, sourceKB: Int64, currentDestKB: Int64) {
        totalKB = max(1, sourceKB)
        let freeKB = freeSpaceKB(at: NSHomeDirectory())

        // For mirror mode the home folder's current content will be deleted as
        // part of the sync, freeing space. The net requirement is only the delta:
        //   neededKB = max(0, sourceKB − currentDestKB)
        // For normal restore we conservatively require the full sourceKB.
        let neededKB: Int64
        if restoreMirrorMode && !restoreDryRunMode {
            // rsync --delete processes directory-by-directory, deleting before
            // transferring within each dir, so peak usage tracks the net delta.
            // Add 10 % margin for bursts where incoming dirs outpace outgoing ones.
            neededKB = Int64(Double(max(0, sourceKB - currentDestKB)) * 1.1)
        } else {
            neededKB = sourceKB
        }

        if freeKB < neededKB && !restoreDryRunMode {
            if restoreMirrorMode {
                spaceCheckMessage = "Not enough space on this Mac. Free: \(gbString(fromKB: freeKB)), needed: ~\(gbString(fromKB: neededKB)) (backup \(gbString(fromKB: sourceKB)) − home \(gbString(fromKB: currentDestKB)) +10 %)"
            } else {
                spaceCheckMessage = "Not enough space on this Mac. Free: \(gbString(fromKB: freeKB)), needed: \(gbString(fromKB: neededKB))"
            }
            appendLog("Restore aborted: insufficient disk space.", type: .error)
            return
        }

        var statusParts: [String] = ["Available on this Mac: \(gbString(fromKB: freeKB))"]
        if !excludedRestorePaths.isEmpty {
            statusParts.append("\(gbString(fromKB: sourceKB)) selected")
        }
        if restoreMirrorMode && !restoreDryRunMode {
            if neededKB < 102_400 {
                statusParts.append("already mostly synced (net delta ≈ 0)")
            } else {
                statusParts.append("~\(gbString(fromKB: neededKB)) net needed (delta +10 %)")
            }
        }
        spaceCheckMessage = "Space check OK ✓  " + statusParts.joined(separator: "  ·  ")
        appendLog("Disk space OK.", type: .success)
        pendingRestorePath = backupFolderPath
        let startRun = {
            self.checkFullDiskAccess {
                self.proceedWithRestore(backupFolderPath: backupFolderPath)
            }
        }
        if !restoreDryRunMode && currentDestKB > restoreInUseThresholdKB {
            restoreInUseHomeKB = currentDestKB
            pendingRestoreInUseContinuation = startRun
            restoreInUseAcknowledged = false
            showRestoreInUseWarning = true
        } else {
            startRun()
        }
    }

    // A freshly set up account is well under this; a Mac in daily use is far above it.
    let restoreInUseThresholdKB: Int64 = 5_000_000_000 / 1024

    func proceedWithRestore(backupFolderPath: String) {
        guard let scriptURL = bundledRestoreScriptURL() else { return }

        appendLog("Restore process started (rsync)...", type: .success)
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        var args = [scriptURL.path, backupFolderPath]
        if restoreDryRunMode   { args.append("--dry-run") }
        if restoreMirrorMode   { args.append("--delete") }
        for path in excludedRestorePaths.sorted() {
            let fullPath = "\(backupFolderPath)/\(path)"
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            args.append("--skip-path=\(path)\(isDir.boolValue ? "/" : "")")
        }
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Capture state needed for per-line processing — these don't change while running.
        let isDryRun = restoreDryRunMode
        let topFolders = Set(restoreTreeItems.filter { $0.depth == 0 }.map { $0.name })
        let capturedDrive = restoreSelectedDrive
        let capturedFolder = selectedBackupFolder

        // Group tracks in-flight background processing blocks AND the process
        // termination handler, so the completion logic (run on pipe EOF) waits
        // until all state updates are done and the exit status is captured.
        let group = DispatchGroup()
        var capturedExitStatus: Int32 = 0

        // rsync output arrives in arbitrary chunks that can split a line (or a
        // multi-byte character) in half — parse only complete buffered lines,
        // keeping the tail until its newline (or EOF) arrives.
        var streamBuffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let isEOF = data.isEmpty
            if !isEOF { streamBuffer.append(data) }
            let cutoff: Data.Index? = isEOF
                ? streamBuffer.endIndex
                : streamBuffer.lastIndex(of: UInt8(ascii: "\n")).map { streamBuffer.index(after: $0) }

            if let cutoff, cutoff > streamBuffer.startIndex {
                let output = String(decoding: streamBuffer[streamBuffer.startIndex..<cutoff], as: UTF8.self)
                streamBuffer.removeSubrange(streamBuffer.startIndex..<cutoff)
                let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { String($0).trimmingCharacters(in: .newlines) }
                let newEntries = lines.filter { line in
                    !line.isEmpty &&
                    !line.hasPrefix("TOTAL_KB=") &&
                    !line.hasPrefix("RAW_SOURCE_KB=") &&
                    !line.hasPrefix("RAW_FILE_COUNT=") &&
                    !line.hasPrefix("XFER_KB=") &&
                    !line.hasPrefix("XFER_LIST=") &&
                    line != "SCAN_START" &&
                    line != "SCAN_END" &&
                    !line.hasPrefix("SOURCE=") &&
                    !line.hasPrefix("RUNNING_AS=") &&
                    !line.hasPrefix("FILE_COUNT=") &&
                    !line.hasPrefix("HOME_RAW_KB=") &&
                    !line.hasPrefix("HOME_SCOPED_KB=")
                }.map { LogEntry(message: $0, type: .info) }

                // All per-line processing runs on the background thread to avoid
                // blocking the main thread with FileManager.attributesOfItem calls.
                var toTransfer: [String: Int] = [:]
                var toTransferSize: [String: Int64] = [:]
                var toDelete: [String: Int] = [:]
                var subCounts: [String: Int] = [:]
                var subSizes: [String: Int64] = [:]
                var fileLines: [String] = []

                for line in lines {
                    if isDryRun && !topFolders.isEmpty {
                        let isDeletion = line.hasPrefix("deleting ") || line.hasPrefix("*deleting ")
                        if isDeletion {
                            let stripped = line.hasPrefix("*") ? String(line.dropFirst()) : line
                            let path = String(stripped.dropFirst("deleting ".count)).trimmingCharacters(in: .whitespaces)
                            let folder = String(path.split(separator: "/", maxSplits: 1).first ?? "")
                            if !folder.isEmpty { toDelete[folder, default: 0] += 1 }
                        } else if line.contains("/") && !line.hasSuffix("/") {
                            let components = line.split(separator: "/")
                            let folder = String(components[0])
                            if topFolders.contains(folder) {
                                let backupFile = "/Volumes/\(capturedDrive)/\(capturedFolder)/\(line)"
                                let fileSize = (try? FileManager.default.attributesOfItem(atPath: backupFile))?[.size] as? Int64 ?? 0
                                toTransfer[folder, default: 0] += 1
                                toTransferSize[folder, default: 0] += fileSize
                                if components.count >= 3 {
                                    let subKey = "\(components[0])/\(components[1])"
                                    subCounts[subKey, default: 0] += 1
                                    subSizes[subKey, default: 0] += fileSize
                                }
                            }
                        }
                    } else if !isDryRun,
                              let first = line.first, first.isLetter,
                              line.contains("/"), !line.hasSuffix("/"),
                              !line.hasPrefix("deleting "), !line.hasPrefix("*deleting ") {
                        fileLines.append(line)
                    }
                }

                group.enter()
                DispatchQueue.main.async {
                    self.restorePendingLogEntries.append(contentsOf: newEntries)
                    if isDryRun {
                        for (k, v) in toTransfer     { self.dryRunToTransferByFolder[k, default: 0] += v }
                        for (k, v) in toTransferSize { self.dryRunToTransferSizeByFolder[k, default: 0] += v }
                        for (k, v) in toDelete       { self.dryRunToDeleteByFolder[k, default: 0] += v }
                        for (k, v) in subCounts      { self.dryRunToTransferBySubfolder[k, default: 0] += v }
                        for (k, v) in subSizes       { self.dryRunToTransferSizeBySubfolder[k, default: 0] += v }
                    } else {
                        self.creditRestoreFiles(fileLines)
                    }
                    self.handleScriptOutput(output)
                    group.leave()
                }
            }

            if isEOF {
                // Pipe EOF — the process has exited and all output has been delivered.
                // Clearing the handler prevents a retain cycle.
                handle.readabilityHandler = nil
                // Wait for any still-in-flight background work (FileManager stats
                // calls, dict merges) to finish updating main-thread state, THEN
                // run the completion / summary logic.
                group.notify(queue: .main) {
                    self.isRunning = false
                    self.refreshMacFreeSpace()
                    self.stopRestoreProgressTimer()
                    self.flushAndStopLogTimer()

                    if self.userCancelled {
                        self.restoreFinishState = .cancelled
                        self.appendLog("Restore cancelled by user.", type: .warning)
                        return
                    }

                    if isDryRun {
                        self.showDryRunSummary(label: "restore")
                    }

                    if !isDryRun, [0, 12, 16, 23, 24].contains(capturedExitStatus),
                       let start = self.restoreStartTime {
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed >= 10 {
                            self.recordSpeed(Double(self.effectiveRestoreDoneKB) / elapsed, forDrive: capturedDrive)
                        }
                    }

                    let restoreLogPath = NSHomeDirectory() + "/Desktop/RsyncRettung_restore_errors.log"
                    // Repeated permission errors writing into an OS-managed container
                    // (e.g. an app's Group Container) can make rsync's local
                    // sender/receiver pipe break, exiting 12 (protocol stream error)
                    // instead of the usual 23/24 — even though only permission
                    // issues, not a real transfer failure, caused it. Route it
                    // through the same skipped-files flow as 16/23/24, but only
                    // when the log actually shows permission/IO errors explaining
                    // it — otherwise a code-12 exit is treated as a real failure,
                    // since it can also mean e.g. the drive was disconnected.
                    let codesWithPossibleSkips: Set<Int32> = [12, 16, 23, 24]
                    if !isDryRun, capturedExitStatus != 0, capturedExitStatus != 30,
                       self.logShowsEarlyStop(restoreLogPath) {
                        self.restoreFinishState = .failed
                        self.appendLog("Restore may have stopped early: rsync's copy process crashed partway through, so files after that point may be missing. Run the restore again, and check the error log if it happens again.", type: .error)
                        self.appendLog("Error log: \(restoreLogPath)", type: .info)
                        return
                    }
                    switch capturedExitStatus {
                    case 0:
                        self.restoreFinishState = .success
                        self.appendLog(
                            isDryRun ? "Dry run complete." : "Restore completed successfully.",
                            type: isDryRun ? .info : .success
                        )
                    case _ where codesWithPossibleSkips.contains(capturedExitStatus):
                        let skipped = self.loadSkippedFiles(logFile: restoreLogPath)
                        self.skippedFiles = skipped
                        if skipped.isEmpty {
                            if capturedExitStatus == 12 {
                                self.restoreFinishState = .failed
                                self.appendLog("Restore failed (code 12: the connection to the source or target may have dropped).", type: .error)
                                self.appendLog("Error log: \(restoreLogPath)", type: .info)
                            } else {
                                self.restoreFinishState = .success
                                self.appendLog(isDryRun ? "Dry run complete." : "Restore complete. A few system protected files were skipped (normal).", type: .success)
                            }
                        } else {
                            self.restoreFinishState = .warnings
                            self.appendLog(isDryRun ? "Dry run complete with warnings." : "Restore completed with warnings.", type: .warning)
                            if !isDryRun {
                                self.appendLog("Error log: \(restoreLogPath)", type: .info)
                            }
                            self.showSkippedFiles(skipped, limit: isDryRun ? .max : 20, logPath: restoreLogPath)
                        }
                    case 30:
                        self.restoreFinishState = .failed
                        self.appendLog("Restore stopped: no data moved for 5 minutes. A file didn't respond or the backup drive stalled. Check the drive connection, then start the restore again. It continues where it stopped.", type: .error)
                        self.appendLog("Error log: \(restoreLogPath)", type: .info)
                    default:
                        self.restoreFinishState = .failed
                        self.appendLog("Restore failed (code: \(capturedExitStatus)).", type: .error)
                        self.appendLog("Error log: \(restoreLogPath)", type: .info)
                    }
                }
            }
        }

        group.enter()
        process.terminationHandler = { proc in
            capturedExitStatus = proc.terminationStatus
            group.leave()
        }

        do {
            try process.run()
            isRunning = true
            restorePinnedLogCount = restoreLogEntries.count
            startLogFlushTimer()
            if !isDryRun { startRestoreProgressTimer() }
        } catch {
            process.terminationHandler = nil
            group.leave()
            pipe.fileHandleForReading.readabilityHandler = nil
            appendLog("Failed to start restore.", type: .error)
        }
    }

    // MARK: - Shared Helpers

    // Loads the pre-scan file list (`<bytes> <relative path>` per line, from
    // rsync --out-format='%l %n') into a path→size map. Parsed off the main
    // thread — the list can hold hundreds of thousands of entries. Files that
    // finished before the map was ready sit in *UncreditedFiles and are
    // credited here.
    func loadXferSizeList(path: String, forBackup: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            var map: [String: Int64] = [:]
            // Lossy UTF-8 decode, matching the live-output decode: openrsync
            // escapes non-ASCII names with raw bytes that strict decoding rejects,
            // and identical decoding on both sides keeps the map keys matching.
            if let data = FileManager.default.contents(atPath: path) {
                let text = String(decoding: data, as: UTF8.self)
                for line in text.split(separator: "\n") {
                    guard let sp = line.firstIndex(of: " "),
                          let bytes = Int64(line[..<sp]) else { continue }
                    let filePath = String(line[line.index(after: sp)...])
                    if !filePath.hasSuffix("/") { map[filePath] = bytes }
                }
            }
            try? FileManager.default.removeItem(atPath: path)
            DispatchQueue.main.async {
                if forBackup {
                    self.xferSizeByPath = map
                    self.xferSizeMapLoaded = true
                    for p in self.backupUncreditedFiles {
                        if let b = self.xferSizeByPath.removeValue(forKey: p) { self.backupRealDoneBytes += b }
                    }
                    self.backupUncreditedFiles = []
                } else {
                    self.restoreXferSizeByPath = map
                    self.restoreXferSizeMapLoaded = true
                    for p in self.restoreUncreditedFiles {
                        if let b = self.restoreXferSizeByPath.removeValue(forKey: p) { self.restoreRealDoneBytes += b }
                    }
                    self.restoreUncreditedFiles = []
                }
            }
        }
    }

    // rsync -v prints a file's name when it STARTS copying it, so a file's
    // real size is credited only once the next file line appears (= previous
    // file finished). The in-flight file's bytes show up via the du delta.
    func creditBackupFiles(_ paths: [String]) {
        for path in paths {
            if let prev = backupPendingFile {
                if let b = xferSizeByPath.removeValue(forKey: prev) {
                    backupRealDoneBytes += b
                } else if !xferSizeMapLoaded {
                    backupUncreditedFiles.append(prev)
                }
            }
            backupPendingFile = path
        }
    }

    func creditRestoreFiles(_ paths: [String]) {
        for path in paths {
            if let prev = restorePendingFile {
                if let b = restoreXferSizeByPath.removeValue(forKey: prev) {
                    restoreRealDoneBytes += b
                } else if !restoreXferSizeMapLoaded {
                    restoreUncreditedFiles.append(prev)
                }
            }
            restorePendingFile = path
        }
    }

    func handleScriptOutput(_ output: String) {
        let isActiveDryRun = activeTab == .backup ? dryRunMode : restoreDryRunMode
        for lineSub in output.split(separator: "\n") {
            let line = String(lineSub)
            if line == "SCAN_START" { isScanning = true }
            if line == "SCAN_END" {
                isScanning = false
                scanCompleted = true
                if activeTab == .restore { restoreStartTime = Date() }
            }
            if line.hasPrefix("XFER_KB=") {
                if let n = Int64(line.replacingOccurrences(of: "XFER_KB=", with: "")) {
                    if activeTab == .backup { xferTotalKB = n } else { restoreXferTotalKB = n }
                }
            }
            if line.hasPrefix("XFER_LIST=") {
                loadXferSizeList(path: String(line.dropFirst("XFER_LIST=".count)), forBackup: activeTab == .backup)
            }
            if line.hasPrefix("RAW_SOURCE_KB=") {
                if let n = Int64(line.replacingOccurrences(of: "RAW_SOURCE_KB=", with: "")) { rawSourceKB = n }
            }
            if line.hasPrefix("RAW_FILE_COUNT=") {
                if let n = Int(line.replacingOccurrences(of: "RAW_FILE_COUNT=", with: "")) { rawFileCount = n }
            }
            if line.hasPrefix("FILE_COUNT=") {
                if let n = Int(line.replacingOccurrences(of: "FILE_COUNT=", with: "")) { restoreFilesTotal = n }
            }
            if line.hasPrefix("HOME_RAW_KB=") {
                if let n = Int64(line.replacingOccurrences(of: "HOME_RAW_KB=", with: "")) { homeFolderKB = n }
            }
            if line.hasPrefix("HOME_SCOPED_KB=") {
                if let n = Int64(line.replacingOccurrences(of: "HOME_SCOPED_KB=", with: "")) { homeFolderScopedKB = n }
            }
            // Backup only: the restore tab computes totalKB itself (source size
            // minus deselected folders); the restore script's TOTAL_KB sentinel
            // is the full du of the backup folder and would overwrite it.
            if line.hasPrefix("TOTAL_KB="), activeTab == .backup {
                if let n = Int64(line.replacingOccurrences(of: "TOTAL_KB=", with: "")) {
                    totalKB = n
                    if scanCompleted {
                        performPostScanSpaceCheck()
                    }
                }
            }
            if line.hasPrefix("TARGET=") {
                targetPath = line.replacingOccurrences(of: "TARGET=", with: "")
            }
            if line.hasPrefix("ERROR_LOG=") {
                backupErrorLogPath = String(line.dropFirst("ERROR_LOG=".count))
            }
            if isActiveDryRun {
                let isStat = line.hasPrefix("Number of") ||
                             line.hasPrefix("Total file size") ||
                             line.hasPrefix("Total transferred file size") ||
                             (line.hasPrefix("sent ") && line.contains("bytes"))
                if isStat { dryRunStats.append(line) }
            }
        }
    }

    func performPostScanSpaceCheck() {
        scanCompleted = false
        let drivePath = "/Volumes/\(selectedDrive)"
        let freeKB = freeSpaceKB(at: drivePath)
        let neededKB = max(Int64(0), totalKB - copiedKB)

        if dryRunMode {
            if neededKB > freeKB {
                spaceCheckMessage = "Note: Insufficient disk space for actual backup (free: \(gbString(fromKB: freeKB)))"
            } else {
                spaceCheckMessage = ""
            }
        } else if isRunning {
            if freeKB < neededKB {
                spaceCheckMessage = "Not enough space on \(selectedDrive). Free: \(gbString(fromKB: freeKB))"
                appendLog("Backup aborted: insufficient disk space.", type: .error)
                process?.terminate()
            } else {
                spaceCheckMessage = "Space check OK ✓  Available on \(selectedDrive): \(gbString(fromKB: freeKB))"
                appendLog("Disk space OK.", type: .success)
                backupStartTime = Date()
                startProgressTimer()
            }
        }
    }

    func startLogFlushTimer() {
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            self.flushPendingLogs()
        }
    }

    func flushAndStopLogTimer() {
        logFlushTimer?.invalidate()
        logFlushTimer = nil
        flushPendingLogs()
    }

    // Only one of backup/restore runs at a time, so a single timer drains
    // both queues; the idle one is always empty and the guard is a no-op.
    func flushPendingLogs() {
        if !backupPendingLogEntries.isEmpty {
            backupLogEntries.append(contentsOf: backupPendingLogEntries)
            backupPendingLogEntries.removeAll()
            let maxTotal = backupPinnedLogCount + 500
            if backupLogEntries.count > maxTotal {
                let deleteCount = backupLogEntries.count - maxTotal
                backupLogEntries.removeSubrange(backupPinnedLogCount ..< backupPinnedLogCount + deleteCount)
            }
        }
        if !restorePendingLogEntries.isEmpty {
            restoreLogEntries.append(contentsOf: restorePendingLogEntries)
            restorePendingLogEntries.removeAll()
            let maxTotal = restorePinnedLogCount + 500
            if restoreLogEntries.count > maxTotal {
                let deleteCount = restoreLogEntries.count - maxTotal
                restoreLogEntries.removeSubrange(restorePinnedLogCount ..< restorePinnedLogCount + deleteCount)
            }
        }
    }

    func showDryRunSummary(label: String) {
        func statInt(_ prefix: String) -> Int? {
            guard let line = dryRunStats.first(where: { $0.hasPrefix(prefix) }),
                  let val = line.components(separatedBy: ":").last else { return nil }
            let digits = val.trimmingCharacters(in: .whitespaces)
                           .components(separatedBy: " ").first ?? ""
            return Int(digits.replacingOccurrences(of: ",", with: ""))
        }
        func statGB(_ prefix: String) -> String? {
            guard let line = dryRunStats.first(where: { $0.hasPrefix(prefix) }),
                  let val = line.components(separatedBy: ":").last,
                  let bytes = parseRsyncSize(val.trimmingCharacters(in: .whitespaces)) else { return nil }
            return gbString(fromKB: bytes / 1024)
        }

        let totalFiles    = statInt("Number of files:")
        let transferFiles = statInt("Number of files transferred:")
        let totalSize     = statGB("Total file size")
        let transferSize  = statGB("Total transferred file size")

        func fmt(_ n: Int?) -> String { n.map { String(format: "%d", $0) } ?? "n/a" }

        let isRestore = label == "restore"
        appendLog("──────── Dry Run Summary ────────", type: .highlight)
        if isRestore {
            appendLog("Backup scope:        \(fmt(totalFiles)) files   \(totalSize ?? "n/a")", type: .highlight)
            let homeScoped = homeFolderScopedKB > 0 ? gbString(fromKB: homeFolderScopedKB) : "measuring..."
            appendLog("Current home (~):    \(homeScoped)", type: .highlight)
            appendLog("Would transfer:      \(fmt(transferFiles)) files   \(transferSize ?? "n/a")", type: .highlight)
            let totalDelete = dryRunToDeleteByFolder.values.reduce(0, +)
            if totalDelete > 0 {
                appendLog("Would delete (mirror): \(fmt(totalDelete)) Mac-only files", type: .error)
            }
            let allFolders = Set(dryRunToTransferByFolder.keys).union(dryRunToDeleteByFolder.keys)
            if !allFolders.isEmpty {
                let sorted = allFolders.sorted {
                    (dryRunToTransferByFolder[$0] ?? 0) + (dryRunToDeleteByFolder[$0] ?? 0) >
                    (dryRunToTransferByFolder[$1] ?? 0) + (dryRunToDeleteByFolder[$1] ?? 0)
                }
                appendLog("── by top-level folder ───────────", type: .highlight)
                for folder in sorted {
                    let toWrite     = dryRunToTransferByFolder[folder] ?? 0
                    let toDel       = dryRunToDeleteByFolder[folder] ?? 0
                    let writeSizeKB = (dryRunToTransferSizeByFolder[folder] ?? 0) / 1024
                    appendLog("  ▸ \(folder):", type: .highlight)
                    if toWrite > 0 {
                        let sz = writeSizeKB > 0 ? "   \(gbString(fromKB: writeSizeKB))" : ""
                        appendLog("      +\(toWrite) files from backup\(sz)", type: .success)
                    }
                    if toDel > 0 {
                        appendLog("      -\(toDel) Mac-only files", type: .error)
                    }

                    let allSubPaths = dryRunToTransferBySubfolder.keys
                        .filter { $0.hasPrefix(folder + "/") }
                        .sorted { (dryRunToTransferSizeBySubfolder[$0] ?? 0) > (dryRunToTransferSizeBySubfolder[$1] ?? 0) }
                    let shownSubPaths = Array(allSubPaths.prefix(5))
                    var shownSubCount = 0
                    var shownSubSizeBytes: Int64 = 0
                    for subPath in shownSubPaths {
                        let subName      = String(subPath.split(separator: "/", maxSplits: 1).last ?? Substring(subPath))
                        let subCount     = dryRunToTransferBySubfolder[subPath] ?? 0
                        let subSizeBytes = dryRunToTransferSizeBySubfolder[subPath] ?? 0
                        let subSizeKB    = subSizeBytes / 1024
                        let szStr        = subSizeKB > 0 ? "   \(gbString(fromKB: subSizeKB))" : ""
                        let subLabel     = ("· " + subName + ":").padding(toLength: 26, withPad: " ", startingAt: 0)
                        appendLog("      \(subLabel)+\(subCount) files\(szStr)", type: .highlight)
                        shownSubCount     += subCount
                        shownSubSizeBytes += subSizeBytes
                    }
                    // Always show remainder so the numbers add up (covers direct files + subfolders beyond top 5)
                    let otherCount  = toWrite - shownSubCount
                    let otherSizeKB = ((dryRunToTransferSizeByFolder[folder] ?? 0) - shownSubSizeBytes) / 1024
                    if otherCount > 0 {
                        let hiddenCount = allSubPaths.count - shownSubPaths.count
                        let moreLabel   = hiddenCount > 0 ? "direct + \(hiddenCount) more sub" : "direct files"
                        let szStr       = otherSizeKB > 0 ? "   \(gbString(fromKB: otherSizeKB))" : ""
                        let subLabel    = ("· (\(moreLabel)):").padding(toLength: 26, withPad: " ", startingAt: 0)
                        appendLog("      \(subLabel)+\(otherCount) files\(szStr)", type: .info)
                    }
                }
            }
        } else {
            appendLog("Home folder (raw):   \(fmt(rawFileCount > 0 ? rawFileCount : nil)) files   \(rawSourceKB > 0 ? gbString(fromKB: rawSourceKB) : "n/a")", type: .highlight)
            appendLog("After excludes:      \(fmt(totalFiles)) files   \(totalSize ?? "n/a")", type: .highlight)
            appendLog("To copy this run:    \(fmt(transferFiles)) files   \(transferSize ?? "n/a")", type: .highlight)
        }
        let drive = isRestore ? restoreSelectedDrive : selectedDrive
        let stored = storedSpeedKBps(forDrive: drive)
        let speedNote = stored != nil
            ? "~\(Int((stored! * 1024 / 1e6).rounded())) MB/s measured"
            : "~50 MB/s assumed"
        let eta = estimatedDryRunETA(forDrive: drive) ?? "unknown"
        appendLog("Est. \(label) time (\(speedNote)): \(eta)", type: .highlight)
        appendLog("─────────────────────────────────", type: .highlight)
    }

    func showSkippedFiles(_ skipped: [String], limit: Int = 20, logPath: String) {
        if skipped.isEmpty {
            appendLog("Some files were inaccessible.", type: .warning)
        } else {
            appendLog("Some inaccessible files were skipped:", type: .warning)
            for line in skipped.prefix(limit) { appendLog(line, type: .warning) }
            if skipped.count > limit {
                appendLog("... and \(skipped.count - limit) more. See \(logPath) for the full list.", type: .warning)
            }
        }
    }

    // Quick statfs-based readout shown as soon as a drive is picked, ahead of
    // the accurate post-scan check in performPostScanSpaceCheck() (which needs
    // the pre-scan's TOTAL_KB and only runs once Start has been pressed).
    // Kept live afterwards by a DriveSpaceWatcher (FSEvents) instead of a
    // timer, so freeing space on the drive updates the label without the
    // user having to reselect the drive or press Start.
    func updateDriveFreeSpaceMessage() {
        guard !selectedDrive.isEmpty else {
            driveFreeSpaceMessage = ""
            driveSpaceWatcher = nil
            return
        }
        refreshDriveFreeSpace()
        driveSpaceWatcher = DriveSpaceWatcher(path: "/Volumes/\(selectedDrive)") {
            refreshDriveFreeSpace()
        }
    }

    func refreshDriveFreeSpace() {
        guard !selectedDrive.isEmpty else { return }
        let freeKB = freeSpaceKB(at: "/Volumes/\(selectedDrive)")
        driveFreeSpaceMessage = "Free on \(selectedDrive): \(gbString(fromKB: freeKB))"
    }

    func refreshMacFreeSpace() {
        macFreeSpaceMessage = "Free on this Mac: \(gbString(fromKB: freeSpaceKB(at: NSHomeDirectory())))"
    }

    func freeSpaceKB(at path: String) -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let freeBytes = attrs[.systemFreeSize] as? Int64 { return freeBytes / 1024 }
        } catch {}
        return 0
    }

    // ETA is recomputed only on the 2 s tick and smoothed against its previous
    // value, so log-flush re-renders can't make the number flap.
    // Speed = longSpeedKBps alone (~2 min EMA). The short EMA is deliberately
    // left out: replaying a recorded 93 GB backup, a ~20 s average let every
    // slow stretch of small files push the ETA from 9 to 22 min and back within
    // a minute (median error 28 %, worst 336 %); the ~2 min average kept the
    // median error at 12 % and never rose more than 11 % per minute. A literal bytes/elapsed
    // running average was used here previously and is deliberately NOT used:
    // its denominator (elapsed) is small for the first several minutes of any
    // multi-hour run, which amplifies a single fast/slow tick into a huge
    // swing in the average — exactly the "jumps from 31 min to 44 min" failure
    // mode. Both EMAs have no such amplification, since each tick only ever
    // moves them by a bounded fraction. No ETA is shown until 15 s of data
    // exists. Final blend is smoothed harder (0.8/0.2, was 0.7/0.3) because a
    // single finished large file can credit a big chunk of bytes in one 2 s
    // tick — the extra damping keeps that from reading as a random jump
    // instead of a real speed change.
    func updateBackupETA() {
        guard let start = backupStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 15 else { return }
        let speed = longSpeedKBps
        guard speed > 1 else { displayedBackupETA = nil; return }
        let raw = Double(remainingKB) / speed
        displayedBackupETA = displayedBackupETA.map { $0 * 0.8 + raw * 0.2 } ?? raw
    }

    func updateRestoreETA() {
        guard let start = restoreStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 15 else { return }
        let speed = longRestoreSpeedKBps
        guard speed > 1 else { displayedRestoreETA = nil; return }
        let raw = Double(restoreRemainingKB) / speed
        displayedRestoreETA = displayedRestoreETA.map { $0 * 0.8 + raw * 0.2 } ?? raw
    }

    func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard self.isRunning, self.totalKB > 1 else { return }
            let username = NSUserName()
            let fallback = "/Volumes/\(self.selectedDrive)/\(username)"
            let path = self.targetPath.isEmpty ? fallback : self.targetPath
            DispatchQueue.global(qos: .utility).async {
                let currentTargetKB = Int64(self.duKB(path))
                DispatchQueue.main.async {
                    let newCopiedKB = max(0, currentTargetKB)
                    self.lastCopiedKB = newCopiedKB
                    self.copiedKB = newCopiedKB
                    // Speed is sampled from effectiveBackupDoneKB (real credited
                    // bytes + in-flight du delta), not raw du growth of the target:
                    // during a rerun that mostly overwrites same-size files, du
                    // barely moves for long stretches even though real transfer is
                    // progressing, which used to starve speedKBps via the decay
                    // branch below and make the ETA swing wildly once that lag
                    // caught up. effectiveBackupDoneKB already accounts for that.
                    let newEffectiveKB = self.effectiveBackupDoneKB
                    let now = Date()
                    if let lastTime = self.lastSampleTime {
                        let dt = now.timeIntervalSince(lastTime)
                        if dt > 0 {
                            let deltaKB = max(0, newEffectiveKB - self.lastEffectiveBackupDoneKB)
                            if deltaKB > 0 {
                                let instantKBps = Double(deltaKB) / dt
                                self.speedKBps = (self.speedKBps * 0.7) + (instantKBps * 0.3)
                                // Slow-decay companion (~2 min time constant) used for the
                                // ETA's long-run estimate instead of raw bytes/elapsed —
                                // a literal running average is most volatile exactly when
                                // it matters most (the first few minutes of a long run,
                                // where a small elapsed denominator amplifies any single
                                // fast/slow tick into a big ETA swing).
                                self.longSpeedKBps = self.longSpeedKBps == 0 ? instantKBps : (self.longSpeedKBps * 0.985) + (instantKBps * 0.015)
                            } else {
                                // Decay instead of freezing so a stalled ETA grows honestly.
                                self.speedKBps *= 0.75
                                self.longSpeedKBps *= 0.995
                            }
                        }
                    }
                    self.lastSampleTime = now
                    self.lastEffectiveBackupDoneKB = newEffectiveKB
                    self.backupDoneFloorKB = max(self.backupDoneFloorKB, newEffectiveKB)
                    self.updateBackupETA()
                }
            }
        }
    }

    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func startRestoreProgressTimer() {
        // Immediate snapshot = baseline; progress is measured as growth from
        // here, so an already-populated home folder doesn't peg the bar at 100 %.
        DispatchQueue.global(qos: .utility).async {
            let kb = Int64(self.duKB(NSHomeDirectory()))
            DispatchQueue.main.async {
                self.restoreBaselineKB = kb
                self.restoreCopiedKB = kb
                self.restoreLastCopiedKB = kb
                self.lastEffectiveRestoreDoneKB = 0
            }
        }
        restoreProgressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard self.isRunning else { return }
            DispatchQueue.global(qos: .utility).async {
                let newKB = Int64(self.duKB(NSHomeDirectory()))
                DispatchQueue.main.async {
                    self.restoreLastCopiedKB = newKB
                    self.restoreCopiedKB = newKB
                    // Same real-bytes speed source as the backup timer — see its
                    // comment for why raw du deltas alone made the ETA jump.
                    let newEffectiveKB = self.effectiveRestoreDoneKB
                    let now = Date()
                    if let lastTime = self.restoreLastSampleTime {
                        let dt = now.timeIntervalSince(lastTime)
                        if dt > 0 {
                            let deltaKB = max(0, newEffectiveKB - self.lastEffectiveRestoreDoneKB)
                            if deltaKB > 0 {
                                let instantKBps = Double(deltaKB) / dt
                                self.restoreSpeedKBps = (self.restoreSpeedKBps * 0.7) + (instantKBps * 0.3)
                                self.longRestoreSpeedKBps = self.longRestoreSpeedKBps == 0 ? instantKBps : (self.longRestoreSpeedKBps * 0.985) + (instantKBps * 0.015)
                            } else {
                                self.restoreSpeedKBps *= 0.75
                                self.longRestoreSpeedKBps *= 0.995
                            }
                        }
                    }
                    self.restoreLastSampleTime = now
                    self.lastEffectiveRestoreDoneKB = newEffectiveKB
                    self.restoreDoneFloorKB = max(self.restoreDoneFloorKB, newEffectiveKB)
                    self.updateRestoreETA()
                }
            }
        }
    }

    func stopRestoreProgressTimer() {
        restoreProgressTimer?.invalidate()
        restoreProgressTimer = nil
    }

    // Throughput measured on past real runs, per drive, so dry-run estimates
    // reflect the actual drive instead of a generic 50 MB/s guess.
    func storedSpeedKBps(forDrive drive: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: "measuredSpeedKBps_\(drive)")
        return v > 0 ? v : nil
    }

    func recordSpeed(_ kbps: Double, forDrive drive: String) {
        guard kbps > 100 else { return }
        let key = "measuredSpeedKBps_\(drive)"
        let old = UserDefaults.standard.double(forKey: key)
        UserDefaults.standard.set(old > 0 ? (old + kbps) / 2 : kbps, forKey: key)
    }

    func estimatedDryRunETA(forDrive drive: String) -> String? {
        guard let line = dryRunStats.first(where: { $0.hasPrefix("Total transferred file size") }),
              let val = line.components(separatedBy: ":").last else { return nil }
        guard let b = parseRsyncSize(val.trimmingCharacters(in: .whitespaces)) else { return nil }
        if b == 0 { return "0s" }
        let speedKBps = storedSpeedKBps(forDrive: drive) ?? (50e6 / 1024)
        return formatDuration(seconds: Double(b) / 1024.0 / speedKBps)
    }

    func parseRsyncSize(_ s: String) -> Int64? {
        var str = s.replacingOccurrences(of: ",", with: "")
                   .trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [
            ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3),
            ("T", 1e12), ("G", 1e9), ("M", 1e6), ("K", 1e3)
        ]
        if str.hasSuffix(" bytes") { str = String(str.dropLast(6)).trimmingCharacters(in: .whitespaces) }
        for (unit, mult) in units {
            for candidate in [" \(unit)", unit] {
                if str.hasSuffix(candidate) {
                    let num = String(str.dropLast(candidate.count))
                    if let n = Double(num) { return Int64(n * mult) }
                }
            }
        }
        return Int64(str)
    }

    func duKB(_ path: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return 0 }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return 0 }
        return Int(out.split(whereSeparator: \.isWhitespace).first ?? "0") ?? 0
    }

    // The per-user TCC database directory is present on every Mac (created by
    // the OS regardless of which apps the user actually uses) and is one of
    // the few paths gated specifically by Full Disk Access rather than any
    // finer-grained per-category permission — a reliable canary. isReadableFile
    // is not usable here: TCC enforcement happens at open/read time, not on the
    // stat-level check that API performs, so it can return true even when a
    // real read would be denied.
    func hasFullDiskAccess() -> Bool {
        let tccDir = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC"
        return (try? FileManager.default.contentsOfDirectory(atPath: tccDir)) != nil
    }

    var fdaPendingIsDryRun: Bool {
        activeTab == .backup ? dryRunMode : restoreDryRunMode
    }

    func checkFullDiskAccess(then proceed: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = self.hasFullDiskAccess()
            DispatchQueue.main.async {
                if granted {
                    proceed()
                } else {
                    self.pendingFDAContinuation = proceed
                    self.fdaWarningAcknowledged = false
                    self.showFDAWarning = true
                }
            }
        }
    }

    // Internal sizes are du's 1024-byte KB; display is decimal (1 GB = 10⁹ bytes) to match Finder.
    func gbString(fromKB kb: Int64) -> String { String(format: "%.2f GB", Double(kb) * 1024 / 1e9) }

    func speedString(fromKBps kbps: Double) -> String { String(format: "%.1f MB/s", kbps * 1024 / 1e6) }

    // Coarser buckets on purpose: second-precision ETAs are fake accuracy and
    // make every fluctuation visible.
    func formatDuration(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 90 { return "\(total) s" }
        if total < 600 {
            let halfMin = Int((Double(total) / 30).rounded()) * 30
            return String(format: "%d:%02d min", halfMin / 60, halfMin % 60)
        }
        if total < 3600 { return "~\((total + 30) / 60) min" }
        let hours = total / 3600
        let mins = Int((Double(total % 3600) / 60 / 5).rounded()) * 5
        if mins == 60 { return "~\(hours + 1) h" }
        return mins == 0 ? "~\(hours) h" : "~\(hours) h \(mins) min"
    }

    // A receiver crash mid-run (seen after permission errors in an
    // OS-managed container) silently drops every file after the crash point.
    func logShowsEarlyStop(_ logFile: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: logFile) else { return false }
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("unexpected end of file")
    }

    func loadSkippedFiles(logFile: String) -> [String] {
        guard let text = try? String(contentsOfFile: logFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { String($0) }
            .filter {
                ($0.contains("Operation not permitted") ||
                 $0.contains("Permission denied") ||
                 $0.contains("Interrupted system call") ||
                 $0.contains("Invalid argument")) &&
                !$0.contains("unreadable directory")
            }
    }

    func color(for type: LogType) -> Color {
        switch type {
        case .info:      return .primary
        case .success:   return .green
        case .warning:   return .yellow
        case .error:     return .red
        case .highlight: return .blue
        }
    }

    func finishBanner(state: FinishState, dryRun: Bool = false) -> some View {
        let (msg, color): (String, Color) = {
            switch state {
            case .success:
                return (dryRun ? "Dry run complete. See summary in log." : "Completed successfully.", .green)
            case .warnings:
                return (dryRun ? "Dry run complete with warnings. See log." : "Finished with warnings. Scroll the log for details.", .orange)
            case .failed:
                return ("Failed. Check the log for details.", .red)
            case .cancelled:
                return ("Cancelled.", .gray)
            }
        }()
        return HStack {
            Text(msg)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }

    func bundledScriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "rsync_swift", withExtension: "zsh") { return url }
        if let url = Bundle.main.url(forResource: "rsync_swift", withExtension: "zsh", subdirectory: "SCRIPTS") { return url }
        return nil
    }

    func bundledRestoreScriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "rsync_restore", withExtension: "zsh") { return url }
        if let url = Bundle.main.url(forResource: "rsync_restore", withExtension: "zsh", subdirectory: "SCRIPTS") { return url }
        return nil
    }

}
