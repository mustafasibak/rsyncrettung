import SwiftUI


enum LogType {
    case info
    case success
    case warning
    case error
}

struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    let type: LogType
}

struct ContentView: View {

    @State private var drives: [String] = []
    @State private var selectedDrive: String = ""
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

    // Calling this closure cancels the DispatchSource and closes the fd.
    // Storing a closure (instead of the source directly) sidesteps
    // Swift's existential-type restrictions on protocol-typed @State vars.
    @State private var stopWatcher: (() -> Void)?

    @State private var showCloudWarning = false
    @State private var cloudWarningAcknowledged = false
    @State private var showAdvancedSettings = false
    @State private var mirrorMode = false
    @State private var includeTrash = false
    @State private var dryRunMode = false

    @State private var showMirrorWarning = false
    @State private var mirrorWarningConfirmed = false
    @State private var mirrorWarningAcknowledged = false
    
    
    
    func appendLog(_ message: String, type: LogType = .info) {
        logEntries.append(LogEntry(message: message, type: type))
    }
    
    var progress: Double {
        guard totalKB > 0 else { return 0 }
        return min(1.0, Double(copiedKB) / Double(totalKB))
    }

    var remainingKB: Int64 {
        return max(0, totalKB - copiedKB)
    }

    var etaSeconds: Double? {
        guard speedKBps > 1 else { return nil }
        return Double(remainingKB) / speedKBps
    }

    var etaString: String {
        guard let s = etaSeconds else { return "ETA: —" }
        return "ETA: \(formatDuration(seconds: s))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("User Folder Backup")
                .font(.largeTitle)

            Picker("Select Backup Drive:", selection: $selectedDrive) {
                ForEach(drives, id: \.self) { drive in
                    Text(drive).tag(drive)
                }
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

            Divider()

            if !spaceCheckMessage.isEmpty {
                Text(spaceCheckMessage)
                    .foregroundColor(spaceCheckMessage.hasPrefix("Not enough") ? .red : .green)
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
            .frame(height: 300)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

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

            HStack {
                Spacer()
                Button("Advanced Settings") {
                    showAdvancedSettings = true
                }
            }

        }
        .padding(20)
        .frame(width: 640, height: 660)

        // CLOUD WARNING Pop Up
        .sheet(isPresented: $showCloudWarning, onDismiss: { cloudWarningAcknowledged = false }) {
            VStack(alignment: .leading, spacing: 20) {

                Text("Before you start")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Data synced with cloud services can cause inaccuracies in the backup process. Please make sure you are logged out of all cloud services before proceeding (e.g. iCloud, Nextcloud, Adobe Creative Cloud)")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)

                Toggle(isOn: $cloudWarningAcknowledged) {
                    Text("I have logged myself out of all cloud services")
                }
                .toggleStyle(.checkbox)

                Spacer()

                HStack {
                    Button("Cancel") {
                        showCloudWarning = false
                    }
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

        // ADVANCED SHEET
        .sheet(isPresented: $showAdvancedSettings) {
            VStack(alignment: .leading, spacing: 20) {
                
                Text("Advanced Settings")
                    .font(.title2)

                Toggle(isOn: $mirrorMode) {
                    VStack(alignment: .leading) {
                        Text("Mirror Backup (--delete)")
                        Text("Deletes files on target that no longer exist on source")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $includeTrash) {
                    VStack(alignment: .leading) {
                        Text("Include Trash")
                        Text("Include user's Trash folder in backup")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $dryRunMode) {
                    VStack(alignment: .leading) {
                        Text("Dry Run (--dry-run)")
                        Text("Preview what would be transferred without copying any files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button("Close") {
                    showAdvancedSettings = false
                }
            }
            .padding(24)
            .frame(width: 400, height: 320)
        }
        
        // MIRROR WARNING Pop Up
        .sheet(isPresented: $showMirrorWarning, onDismiss: {
            if mirrorWarningConfirmed {
                mirrorWarningConfirmed = false
                mirrorWarningAcknowledged = false
                showCloudWarning = true
            }
        }) {
            VStack(alignment: .leading, spacing: 20) {

                Text("Mirror Mode is Enabled")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Mirror mode will delete files on the backup drive that no longer exist on this Mac. This cannot be undone. Make sure you intentionally enabled this option before continuing.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)

                Toggle(isOn: $mirrorWarningAcknowledged) {
                    Text("I understand that files may be permanently deleted from the backup drive")
                }
                .toggleStyle(.checkbox)

                Spacer()

                HStack {
                    Button("Cancel") {
                        showMirrorWarning = false
                    }
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

            if let u = bundledScriptURL() {
                print("DEBUG script path:", u.path)
            }

            startVolumeWatcher()
        }
        .onDisappear {
            stopVolumeWatcher()
        }

    }

    func startVolumeWatcher() {
        // O_EVTONLY opens the directory for event observation only —
        // we don't need to read its contents through this fd.
        let fd = open("/Volumes", O_EVTONLY)
        guard fd >= 0 else { return }

        // makeFileSystemObjectSource registers a kernel kqueue event on fd.
        // The .write mask fires when directory entries change, which is
        // exactly what happens when a volume is mounted or ejected.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)   // run handler on a background thread
        )

        source.setEventHandler {
            // Re-scan /Volumes, then update UI state on the main thread.
            let updated = detectDrives()
            DispatchQueue.main.async {
                drives = updated

                // If the selected drive was ejected, fall back gracefully
                // instead of keeping a stale name in the picker.
                if !updated.contains(selectedDrive) {
                    selectedDrive = updated.first ?? ""
                }
            }
        }

        // The cancel handler is guaranteed to run after the last event handler
        // fires, so closing the fd here is safe — no race condition.
        source.setCancelHandler {
            close(fd)
        }

        // resume() activates the source. DispatchSources start suspended;
        // nothing fires until this call.
        source.resume()

        // Capture `source` strongly in the closure so ARC keeps it alive
        // for as long as stopWatcher exists. Setting stopWatcher = nil
        // drops the closure, drops the source, and ARC deallocates it.
        stopWatcher = { source.cancel() }
    }

    func stopVolumeWatcher() {
        // Calling the closure runs source.cancel(), which:
        //   1. stops new events from firing
        //   2. runs the cancel handler (closes the fd)
        stopWatcher?()
        stopWatcher = nil
    }

    func detectDrives() -> [String] {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(atPath: "/Volumes") else { return [] }

        return items.filter { name in
            let fullPath = "/Volumes/" + name
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: fullPath, isDirectory: &isDir) &&
                   isDir.boolValue &&
                   fileManager.isWritableFile(atPath: fullPath) &&
                   !["Macintosh HD", "Preboot", "VM", "Recovery"].contains(name)
        }
    }

    func color(for type: LogType) -> Color {
        switch type {
        case .info:
            return .primary
        case .success:
            return .green
        case .warning:
            return .yellow
        case .error:
            return .red
        }
    }
    
    func weight(for type: LogType) -> Font.Weight {
        switch type {
        case .info:
            return .regular
        case .success:
            return .bold
        case .warning:
            return .regular
        case .error:
            return .medium
        }
    }
    
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

        if mirrorMode {
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
        
        // Argumente passed into Script
        
        var args = [scriptURL.path, selectedDrive]

        if mirrorMode {
            args.append("--delete")
        }

        if includeTrash {
            args.append("--include-trash")
        }

        if dryRunMode {
            args.append("--dry-run")
        }

        process.arguments = args
        
        
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                DispatchQueue.main.async {
                    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                        let text = String(line).trimmingCharacters(in: .newlines)
                        if !text.isEmpty {
                            self.appendLog(text)
                        }
                    }
                    self.handleScriptOutput(output)
                }
            }
        }

        do {
            try process.run()
            isRunning = true
            if dryRunMode {
                appendLog("DRY RUN: No files will be copied. Showing what would be transferred.", type: .warning)
            } else {
                startProgressTimer()
            }
        } catch {
            appendLog("Failed to start backup.\n", type: .error)
        }

        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                isRunning = false
                stopProgressTimer()

                if userCancelled {
                    appendLog("Backup cancelled by user.", type: .warning)
                } else if proc.terminationStatus == 0 {
                    if dryRunMode {
                        appendLog("Dry run complete. No files were copied.", type: .info)
                    } else {
                        appendLog("Backup completed successfully.", type: .success)
                    }
                } else if proc.terminationStatus == 23 {
                    let skipped = loadSkippedFiles(from: targetPath)
                    skippedFiles = skipped
                    
                    appendLog("Backup completed with warnings.", type: .warning)
                    appendLog("Some inaccessible files were skipped:", type: .warning)
                    
                    for line in skipped.prefix(20) {
                        appendLog(line, type: .warning)
                    }
                    
                    if skipped.count > 20 {
                        appendLog("... and \(skipped.count - 20) more. See rsync_errors.log for full list.", type: .warning)
                    }
                } else {
                    appendLog("Backup failed (code: \(proc.terminationStatus)).", type: .error)
                }
            }
        }
    }

    func handleScriptOutput(_ output: String) {
        for lineSub in output.split(separator: "\n") {
            let line = String(lineSub)

            if line.hasPrefix("TOTAL_KB=") {
                let v = line.replacingOccurrences(of: "TOTAL_KB=", with: "")
                if let n = Int64(v) { totalKB = n }
            }

            if line.hasPrefix("TARGET=") {
                targetPath = line.replacingOccurrences(of: "TARGET=", with: "")
            }
        }
    }

    func freeSpaceKB(at path: String) -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let freeBytes = attrs[.systemFreeSize] as? Int64 {
                return freeBytes / 1024
            }
        } catch {
            print("Disk space check failed")
        }
        return 0
    }

    func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard self.isRunning else { return }
            guard self.totalKB > 1 else { return }

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
                        let instantKBps = Double(deltaKB) / dt
                        self.speedKBps = (self.speedKBps * 0.7) + (instantKBps * 0.3)
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

        let firstToken = out.split(whereSeparator: \.isWhitespace).first
        return Int(firstToken ?? "0") ?? 0
    }

    func gib(fromKB kb: Int64) -> Double {
        Double(kb) / 1024 / 1024
    }

    func gibString(fromKB kb: Int64) -> String {
        String(format: "%.2f GiB", gib(fromKB: kb))
    }

    func speedString(fromKBps kbps: Double) -> String {
        let mibPerSec = kbps / 1024.0
        return String(format: "%.2f MiB/s", mibPerSec)
    }

    func formatDuration(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
    
    func loadSkippedFiles(from targetPath: String) -> [String] {
        let logPath = "\(targetPath)/rsync_errors.log"
        
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return []
        }
        
        return text
            .split(separator: "\n")
            .map { line in
                String(line).replacingOccurrences(of: "rsync(", with: "rsync(")
            }
            .filter {
                $0.contains("Operation not permitted") ||
                $0.contains("Permission denied") ||
                $0.contains("Interrupted system call") ||
                $0.contains("Invalid argument")
            }
    }

    func bundledScriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "rsync_swift", withExtension: "zsh") { return url }
        if let url = Bundle.main.url(forResource: "rsync_swift", withExtension: "zsh", subdirectory: "SCRIPTS") { return url }
        return nil
    }
}
