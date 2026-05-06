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

    @State private var showAdvancedSettings = false
    @State private var mirrorMode = false
    @State private var includeTrash = false
    
    
    
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

        }
        .padding(16)
        .frame(width: 720, height: 520)
        
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

                Spacer()

                Button("Close") {
                    showAdvancedSettings = false
                }
            }
            .padding()
            .frame(width: 400, height: 200)
        }
        
        
        .onAppear {
            drives = detectDrives()
            if selectedDrive.isEmpty, let first = drives.first {
                selectedDrive = first
            }

            if let u = bundledScriptURL() {
                print("DEBUG script path:", u.path)
            }
        }
        
        Button("Advanced Settings") {
            showAdvancedSettings = true
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .bottomTrailing)
        
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button("TEST BUTTON"){
                    
                }
            
            }
        }

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
        guard let scriptURL = bundledScriptURL() else {
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
        
        let freeKB = freeSpaceKB(at: drivePath)

        if freeKB < totalKB {
            spaceCheckMessage = "Not enough space on \(selectedDrive). Free: \(gibString(fromKB: freeKB))"
            appendLog("Backup aborted: insufficient disk space.", type: .error)
            return
        } else {
            spaceCheckMessage = "Space check OK ✓  Available on \(selectedDrive): \(gibString(fromKB: freeKB))"
            appendLog("Disk space OK. Starting backup...", type: .success)
        }

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
            startProgressTimer()
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
                    appendLog("Backup completed successfully.", type: .success)
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
