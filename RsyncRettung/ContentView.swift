import SwiftUI

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

struct ContentView: View {

    // MARK: - Shared State
    @State private var drives: [String] = []
    @State private var logEntries: [LogEntry] = []
    @State private var isRunning = false
    @State private var process: Process?
    @State private var skippedFiles: [String] = []
    @State private var totalKB: Int64 = 1
    @State private var copiedKB: Int64 = 0
    @State private var targetPath: String = ""
    @State private var progressTimer: Timer?
    @State private var userCancelled = false
    @State private var lastCopiedKB: Int64 = 0
    @State private var lastSampleTime: Date?
    @State private var speedKBps: Double = 0
    @State private var spaceCheckMessage: String = ""
    @State private var pendingLogEntries: [LogEntry] = []
    @State private var logFlushTimer: Timer?
    @State private var dryRunStats: [String] = []
    @State private var pinnedLogCount: Int = 0
    @State private var isScanning = false
    @State private var stopWatcher: (() -> Void)?
    @State private var activeTab: AppTab = .backup

    // MARK: - Backup State
    @State private var selectedDrive: String = ""
    @State private var showCloudWarning = false
    @State private var cloudWarningAcknowledged = false
    @State private var showAdvancedSettings = false
    @State private var mirrorMode = false
    @State private var includeTrash = false
    @State private var dryRunMode = false
    @State private var showMirrorWarning = false
    @State private var mirrorWarningConfirmed = false
    @State private var mirrorWarningAcknowledged = false

    // MARK: - Restore State
    @State private var restoreSelectedDrive: String = ""
    @State private var backupFolders: [String] = []
    @State private var selectedBackupFolder: String = ""
    @State private var restoreDryRunMode = false

    // MARK: - Finish State
    @State private var backupFinishState: FinishState? = nil
    @State private var restoreFinishState: FinishState? = nil

    // MARK: - Computed

    func appendLog(_ message: String, type: LogType = .info) {
        logEntries.append(LogEntry(message: message, type: type))
    }

    var progress: Double {
        guard totalKB > 0 else { return 0 }
        return min(1.0, Double(copiedKB) / Double(totalKB))
    }

    var remainingKB: Int64 { max(0, totalKB - copiedKB) }

    var etaSeconds: Double? {
        guard speedKBps > 1 else { return nil }
        return Double(remainingKB) / speedKBps
    }

    var etaString: String {
        guard let s = etaSeconds else { return "ETA: —" }
        return "ETA: \(formatDuration(seconds: s))"
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
                .disabled(isRunning)
                if activeTab == .restore {
                    Text("bin noch dran")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
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
                        spaceCheckMessage.hasPrefix("Not enough") || spaceCheckMessage.hasPrefix("Insufficient")
                            ? .red : .green
                    )
                    .font(.system(.footnote, design: .monospaced))
            }

            Text("Log Output:")

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(logEntries) { entry in
                        Text(entry.message)
                            .foregroundColor(color(for: entry.type))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
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
                    Toggle(isOn: $restoreDryRunMode) {
                        VStack(alignment: .leading) {
                            Text("Dry Run")
                            Text("Preview what would be restored without copying any files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isRunning)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 720)

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
        .sheet(isPresented: $showMirrorWarning, onDismiss: {
            if mirrorWarningConfirmed {
                mirrorWarningConfirmed = false
                mirrorWarningAcknowledged = false
                showCloudWarning = true
            }
        }) {
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
                    Button("Cancel") { showMirrorWarning = false }
                    Spacer()
                    Button("Continue") {
                        mirrorWarningConfirmed = true
                        showMirrorWarning = false
                    }
                    .disabled(!mirrorWarningAcknowledged)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 420, height: 260)
        }

        .onAppear {
            drives = detectDrives()
            if selectedDrive.isEmpty, let first = drives.first {
                selectedDrive = first
            }
            if restoreSelectedDrive.isEmpty, let first = drives.first {
                restoreSelectedDrive = first
                backupFolders = detectBackupFolders(onDrive: first)
                selectedBackupFolder = backupFolders.first ?? ""
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

        HStack {
            Button("Start Backup") { startBackup() }
                .disabled(selectedDrive.isEmpty || isRunning)
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
        .onChange(of: restoreSelectedDrive) { newValue in
            backupFolders = detectBackupFolders(onDrive: newValue)
            selectedBackupFolder = backupFolders.first ?? ""
        }

        Picker("Select Backup Folder:", selection: $selectedBackupFolder) {
            if backupFolders.isEmpty {
                Text("No folders found on drive").tag("")
            } else {
                ForEach(backupFolders, id: \.self) { Text($0).tag($0) }
            }
        }
        .frame(width: 300)

        HStack {
            Button("Start Restore") { startRestore() }
                .disabled(restoreSelectedDrive.isEmpty || selectedBackupFolder.isEmpty || isRunning)
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
                    ProgressView(value: progress).frame(maxWidth: 260)
                    Text("\(Int(progress * 100))%").font(.system(.footnote, design: .monospaced))
                }
                Text("\(gibString(fromKB: copiedKB)) / \(gibString(fromKB: totalKB))")
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
                Text("Dry run in progress — no files are being copied")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(maxWidth: 260)
                Text("\(Int(progress * 100))%")
                    .font(.system(.footnote, design: .monospaced))
                Text("Speed: \(speedString(fromKBps: speedKBps))")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("\(gibString(fromKB: copiedKB)) / \(gibString(fromKB: totalKB))")
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
        } else if isRunning {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text(restoreDryRunMode ? "Dry run in progress — no files are being copied" : "Restore in progress...")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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
        return items.filter { name in
            let path = "/Volumes/" + name
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) &&
                   isDir.boolValue &&
                   fm.isWritableFile(atPath: path) &&
                   !["Macintosh HD", "Preboot", "VM", "Recovery"].contains(name)
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

    // MARK: - Backup

    func startBackup() {
        guard bundledScriptURL() != nil else {
            appendLog("Script not found.", type: .error)
            return
        }
        userCancelled = false
        lastSampleTime = nil
        speedKBps = 0
        targetPath = ""
        skippedFiles = []
        dryRunStats = []
        pinnedLogCount = 0
        isScanning = false
        backupFinishState = nil
        stopProgressTimer()

        appendLog("Checking target drive...")
        appendLog("Checking available disk space...")
        let drivePath = "/Volumes/\(selectedDrive)"
        let username = NSUserName()
        let targetFolder = "\(drivePath)/\(username)"

        let currentTargetKB = Int64(duKB(targetFolder))
        copiedKB = currentTargetKB
        lastCopiedKB = currentTargetKB

        let sourceKB = Int64(duKB(NSHomeDirectory()))
        totalKB = max(1, sourceKB)

        let freeKB = freeSpaceKB(at: drivePath)

        if freeKB < totalKB {
            if dryRunMode {
                spaceCheckMessage = "Insufficient space for actual backup on \(selectedDrive). Free: \(gibString(fromKB: freeKB)) — simulating in dry run"
                appendLog("Note: Insufficient disk space for actual backup. Proceeding as dry run only.", type: .warning)
            } else {
                spaceCheckMessage = "Not enough space on \(selectedDrive). Free: \(gibString(fromKB: freeKB))"
                appendLog("Backup aborted: insufficient disk space.", type: .error)
                return
            }
        } else {
            spaceCheckMessage = "Space check OK ✓  Available on \(selectedDrive): \(gibString(fromKB: freeKB))"
            appendLog("Disk space OK.", type: .success)
        }

        if dryRunMode {
            proceedWithBackup()
        } else if mirrorMode {
            showMirrorWarning = true
        } else {
            showCloudWarning = true
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

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
            let newEntries = output.split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .newlines) }
                .filter { line in
                    !line.isEmpty &&
                    !line.hasPrefix("TOTAL_KB=") &&
                    !line.hasPrefix("TARGET=") &&
                    line != "SCAN_START" &&
                    line != "SCAN_END" &&
                    !line.hasPrefix("RUNNING_AS=") &&
                    !line.hasPrefix("PWD=")
                }
                .map { LogEntry(message: $0, type: .info) }
            DispatchQueue.main.async {
                self.pendingLogEntries.append(contentsOf: newEntries)
                self.handleScriptOutput(output)
            }
        }

        do {
            try process.run()
            isRunning = true
            pinnedLogCount = logEntries.count
            startLogFlushTimer()
        } catch {
            appendLog("Failed to start backup.", type: .error)
        }

        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                self.isRunning = false
                self.stopProgressTimer()
                self.flushAndStopLogTimer()

                if self.userCancelled {
                    self.backupFinishState = .cancelled
                    self.appendLog("Backup cancelled by user.", type: .warning)
                    return
                }

                if self.dryRunMode && !self.dryRunStats.isEmpty {
                    self.showDryRunSummary(label: "copy")
                }

                switch proc.terminationStatus {
                case 0:
                    self.backupFinishState = .success
                    self.appendLog(
                        self.dryRunMode ? "Dry run complete." : "Backup completed successfully.",
                        type: self.dryRunMode ? .info : .success
                    )
                case 23:
                    let skipped = self.loadSkippedFiles(logFile: "\(self.targetPath)/rsync_errors.log")
                    self.skippedFiles = skipped
                    self.backupFinishState = .warnings
                    self.appendLog(self.dryRunMode ? "Dry run complete with warnings." : "Backup completed with warnings.", type: .warning)
                    self.showSkippedFiles(skipped)
                default:
                    self.backupFinishState = .failed
                    self.appendLog("Backup failed (code: \(proc.terminationStatus)).", type: .error)
                }
            }
        }
    }

    // MARK: - Restore

    func startRestore() {
        guard bundledRestoreScriptURL() != nil else {
            appendLog("Restore script not found.", type: .error)
            return
        }
        guard !selectedBackupFolder.isEmpty else { return }

        userCancelled = false
        lastSampleTime = nil
        speedKBps = 0
        skippedFiles = []
        dryRunStats = []
        pinnedLogCount = 0
        restoreFinishState = nil
        stopProgressTimer()

        let backupFolderPath = "/Volumes/\(restoreSelectedDrive)/\(selectedBackupFolder)"
        appendLog("Checking backup source...")

        guard FileManager.default.fileExists(atPath: backupFolderPath) else {
            appendLog("Backup folder not found: \(backupFolderPath)", type: .error)
            return
        }

        let sourceKB = Int64(duKB(backupFolderPath))
        totalKB = max(1, sourceKB)
        let freeKB = freeSpaceKB(at: "/")

        if freeKB < sourceKB && !restoreDryRunMode {
            spaceCheckMessage = "Not enough space on startup disk. Free: \(gibString(fromKB: freeKB)), needed: \(gibString(fromKB: sourceKB))"
            appendLog("Restore aborted: insufficient disk space.", type: .error)
            return
        }

        spaceCheckMessage = "Space check OK ✓  Available: \(gibString(fromKB: freeKB))"
        appendLog("Disk space OK.", type: .success)
        proceedWithRestore(backupFolderPath: backupFolderPath)
    }

    func proceedWithRestore(backupFolderPath: String) {
        guard let scriptURL = bundledRestoreScriptURL() else { return }

        appendLog("Restore process started (rsync)...", type: .success)
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        var args = [scriptURL.path, backupFolderPath]
        if restoreDryRunMode { args.append("--dry-run") }
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
            let newEntries = output.split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .newlines) }
                .filter { !$0.isEmpty }
                .map { LogEntry(message: $0, type: .info) }
            DispatchQueue.main.async {
                self.pendingLogEntries.append(contentsOf: newEntries)
                self.handleScriptOutput(output)
            }
        }

        do {
            try process.run()
            isRunning = true
            pinnedLogCount = logEntries.count
            startLogFlushTimer()
        } catch {
            appendLog("Failed to start restore.", type: .error)
        }

        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                self.isRunning = false
                self.flushAndStopLogTimer()

                if self.userCancelled {
                    self.restoreFinishState = .cancelled
                    self.appendLog("Restore cancelled by user.", type: .warning)
                    return
                }

                if self.restoreDryRunMode && !self.dryRunStats.isEmpty {
                    self.showDryRunSummary(label: "restore")
                }

                switch proc.terminationStatus {
                case 0:
                    self.restoreFinishState = .success
                    self.appendLog(
                        self.restoreDryRunMode ? "Dry run complete." : "Restore completed successfully.",
                        type: self.restoreDryRunMode ? .info : .success
                    )
                    if !self.restoreDryRunMode {
                        self.appendLog("Please restart your Mac to finalize all changes.", type: .warning)
                    }
                case 23:
                    let skipped = self.loadSkippedFiles(logFile: "/tmp/rsync_restore_errors.log")
                    self.skippedFiles = skipped
                    self.restoreFinishState = .warnings
                    self.appendLog(self.restoreDryRunMode ? "Dry run complete with warnings." : "Restore completed with warnings.", type: .warning)
                    if !self.restoreDryRunMode {
                        self.appendLog("Please restart your Mac to finalize all changes.", type: .warning)
                    }
                    self.showSkippedFiles(skipped)
                default:
                    self.restoreFinishState = .failed
                    self.appendLog("Restore failed (code: \(proc.terminationStatus)).", type: .error)
                }
            }
        }
    }

    // MARK: - Shared Helpers

    func handleScriptOutput(_ output: String) {
        let isActiveDryRun = activeTab == .backup ? dryRunMode : restoreDryRunMode
        for lineSub in output.split(separator: "\n") {
            let line = String(lineSub)
            if line == "SCAN_START" { isScanning = true }
            if line == "SCAN_END" {
                isScanning = false
                if activeTab == .backup && !dryRunMode && isRunning {
                    startProgressTimer()
                }
            }
            if line.hasPrefix("TOTAL_KB=") {
                if let n = Int64(line.replacingOccurrences(of: "TOTAL_KB=", with: "")) { totalKB = n }
            }
            if line.hasPrefix("TARGET=") {
                targetPath = line.replacingOccurrences(of: "TARGET=", with: "")
            }
            if isActiveDryRun {
                let isStat = line.hasPrefix("Number of") ||
                             line.hasPrefix("Total file size") ||
                             line.hasPrefix("Total transferred file size") ||
                             (line.hasPrefix("sent ") && line.contains("bytes")) ||
                             line.contains("total size is")
                if isStat { dryRunStats.append(line) }
            }
        }
    }

    func startLogFlushTimer() {
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            guard !self.pendingLogEntries.isEmpty else { return }
            self.logEntries.append(contentsOf: self.pendingLogEntries)
            self.pendingLogEntries.removeAll()
            let maxTotal = self.pinnedLogCount + 500
            if self.logEntries.count > maxTotal {
                let deleteCount = self.logEntries.count - maxTotal
                self.logEntries.removeSubrange(self.pinnedLogCount ..< self.pinnedLogCount + deleteCount)
            }
        }
    }

    func flushAndStopLogTimer() {
        logFlushTimer?.invalidate()
        logFlushTimer = nil
        guard !pendingLogEntries.isEmpty else { return }
        logEntries.append(contentsOf: pendingLogEntries)
        pendingLogEntries.removeAll()
        let maxTotal = pinnedLogCount + 500
        if logEntries.count > maxTotal {
            let deleteCount = logEntries.count - maxTotal
            logEntries.removeSubrange(pinnedLogCount ..< pinnedLogCount + deleteCount)
        }
    }

    func showDryRunSummary(label: String) {
        appendLog("──────── Dry Run Summary ────────", type: .highlight)
        for stat in dryRunStats {
            if stat.hasPrefix("sent ") { continue }
            if stat.contains("total size is") {
                let after = stat.components(separatedBy: "total size is").last ?? stat
                let size = after.trimmingCharacters(in: .whitespaces)
                              .components(separatedBy: "  ").first ?? after
                appendLog("Total source size: \(size.trimmingCharacters(in: .whitespaces))", type: .highlight)
                continue
            }
            appendLog(stat, type: .highlight)
        }
        if let eta = estimatedDryRunETA() {
            appendLog("Est. \(label) time (~50 MB/s): \(eta)", type: .highlight)
        }
        appendLog("─────────────────────────────────", type: .highlight)
    }

    func showSkippedFiles(_ skipped: [String]) {
        if skipped.isEmpty {
            appendLog("Some files were inaccessible.", type: .warning)
        } else {
            appendLog("Some inaccessible files were skipped:", type: .warning)
            for line in skipped.prefix(20) { appendLog(line, type: .warning) }
            if skipped.count > 20 {
                appendLog("... and \(skipped.count - 20) more.", type: .warning)
            }
        }
    }

    func freeSpaceKB(at path: String) -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let freeBytes = attrs[.systemFreeSize] as? Int64 { return freeBytes / 1024 }
        } catch {}
        return 0
    }

    func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard self.isRunning, self.totalKB > 1 else { return }
            let username = NSUserName()
            let fallback = "/Volumes/\(self.selectedDrive)/\(username)"
            let path = self.targetPath.isEmpty ? fallback : self.targetPath
            let currentTargetKB = Int64(self.duKB(path))
            DispatchQueue.main.async {
                let newCopiedKB = max(0, currentTargetKB)
                let now = Date()
                if let lastTime = self.lastSampleTime {
                    let dt = now.timeIntervalSince(lastTime)
                    if dt > 0 {
                        let deltaKB = max(0, newCopiedKB - self.lastCopiedKB)
                        if deltaKB > 0 {
                            let instantKBps = Double(deltaKB) / dt
                            self.speedKBps = (self.speedKBps * 0.7) + (instantKBps * 0.3)
                        }
                    }
                }
                self.lastSampleTime = now
                self.lastCopiedKB = newCopiedKB
                self.copiedKB = newCopiedKB
            }
        }
    }

    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func estimatedDryRunETA() -> String? {
        let transferLine = dryRunStats.first { $0.hasPrefix("Total transferred file size") }
        let totalLine    = dryRunStats.first { $0.contains("total size is") }
        var bytes: Int64?
        if let line = transferLine, let val = line.components(separatedBy: ":").last {
            bytes = parseRsyncSize(val.trimmingCharacters(in: .whitespaces))
        } else if let line = totalLine {
            let after = line.components(separatedBy: "total size is").last ?? ""
            let token = after.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            bytes = parseRsyncSize(token)
        }
        guard let b = bytes, b > 0 else { return nil }
        return formatDuration(seconds: Double(b) / (50 * 1024 * 1024))
    }

    func parseRsyncSize(_ s: String) -> Int64? {
        var str = s.replacingOccurrences(of: " bytes", with: "")
                   .replacingOccurrences(of: ",", with: "")
                   .trimmingCharacters(in: .whitespaces)
        for (suffix, mult) in [("T", 1e12), ("G", 1e9), ("M", 1e6), ("K", 1e3)] as [(String, Double)] {
            if str.hasSuffix(suffix) {
                str = String(str.dropLast())
                if let n = Double(str) { return Int64(n * mult) }
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

    func gib(fromKB kb: Int64) -> Double { Double(kb) / 1024 / 1024 }

    func gibString(fromKB kb: Int64) -> String { String(format: "%.2f GiB", gib(fromKB: kb)) }

    func speedString(fromKBps kbps: Double) -> String { String(format: "%.2f MiB/s", kbps / 1024.0) }

    func formatDuration(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    func loadSkippedFiles(logFile: String) -> [String] {
        guard let text = try? String(contentsOfFile: logFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { String($0) }
            .filter {
                $0.contains("Operation not permitted") ||
                $0.contains("Permission denied") ||
                $0.contains("Interrupted system call") ||
                $0.contains("Invalid argument")
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
                return (dryRun ? "Dry run complete — see summary in log." : "Completed successfully.", .green)
            case .warnings:
                return (dryRun ? "Dry run complete with warnings — see log." : "Finished with warnings — scroll log for details.", .orange)
            case .failed:
                return ("Failed — check log for details.", .red)
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
