import SwiftUI
import Foundation
import AppKit
import MonitorCore

// MARK: - Ollama API

// MARK: - Persistent Settings

struct MonitorSettingsData: Codable {
    var serverURL = "http://127.0.0.1:11434"
    var logPath = "~/.ollama/logs/server.log"
    var appPath = "Ollama"
    var refreshInterval = 0.5
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var serverURL: String { didSet { save() } }
    @Published var logPath: String { didSet { save() } }
    @Published var appPath: String { didSet { save() } }
    @Published var refreshInterval: Double { didSet { save() } }

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/OllamaMonitor",
                isDirectory: true
            )
            .appendingPathComponent("config.json")
    }

    private init() {
        var data = MonitorSettingsData()

        if let file = try? Data(contentsOf: Self.configURL),
           let saved = try? JSONDecoder().decode(
               MonitorSettingsData.self, from: file
           ) {
            data = saved
        }

        serverURL = data.serverURL
        logPath = data.logPath
        appPath = data.appPath
        refreshInterval = [0.5, 1, 2, 3, 5].contains(data.refreshInterval)
            ? data.refreshInterval : 0.5
    }

    var expandedLogURL: URL {
        URL(fileURLWithPath:
            (logPath as NSString).expandingTildeInPath
        )
    }

    var appDisplayName: String {
        let value = appPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Ollama" }
        return URL(fileURLWithPath: value)
            .deletingPathExtension().lastPathComponent
    }

    func restoreDefaults() {
        serverURL = "http://127.0.0.1:11434"
        logPath = "~/.ollama/logs/server.log"
        appPath = "Ollama"
        refreshInterval = 0.5
    }

    private func save() {
        let data = MonitorSettingsData(
            serverURL: serverURL,
            logPath: logPath,
            appPath: appPath,
            refreshInterval: refreshInterval
        )

        do {
            let directory = Self.configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: Self.configURL, options: .atomic)
        } catch {
            NSLog("Ollama Monitor: Could not save settings: %@", error.localizedDescription)
        }
    }
}

// MARK: - Monitor

private struct ControlCommandFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func runControlCommand(
    _ executablePath: String,
    arguments: [String]
) throws {
    let process = Process()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorPipe

    do {
        try process.run()
    } catch {
        throw ControlCommandFailure(
            message: "Could not run \(URL(fileURLWithPath: executablePath).lastPathComponent): \(error.localizedDescription)"
        )
    }

    process.waitUntilExit()
    let errorText = String(
        data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard process.terminationStatus == 0 else {
        let details = errorText.isEmpty
            ? "Command exited with status \(process.terminationStatus)."
            : errorText
        throw ControlCommandFailure(message: details)
    }
}

private final class HTTPProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func ollamaAPIResponds(serverURL: String) -> Bool {
    let base = serverURL
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    guard let url = URL(string: base + "/api/ps") else { return false }

    var request = URLRequest(url: url)
    request.timeoutInterval = 1

    let result = HTTPProbeResult()
    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { _, response, error in
        result.set(
            error == nil && (response as? HTTPURLResponse)?.statusCode == 200
        )
        semaphore.signal()
    }
    task.resume()

    guard semaphore.wait(timeout: .now() + 1.5) == .success else {
        task.cancel()
        return false
    }
    return result.get()
}

private func waitForOllama(
    serverURL: String,
    online expectedOnline: Bool,
    timeout: TimeInterval = 15
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var consecutiveMatches = 0

    while Date() < deadline {
        if ollamaAPIResponds(serverURL: serverURL) == expectedOnline {
            consecutiveMatches += 1
            if consecutiveMatches >= 2 { return true }
        } else {
            consecutiveMatches = 0
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return false
}

@MainActor
final class Monitor: ObservableObject {

    // Connection
    @Published var ollamaOnline = false
    @Published var isBusy = false
    @Published var controlMessage = ""
    @Published var controlMessageIsError = false
    @Published private(set) var loadedModels: [OllamaLoadedModel] = []
    @Published private(set) var unloadingModels: Set<String> = []
    @Published private(set) var lastSuccessfulPoll: Date?
    @Published private(set) var monitoringStale = true

    // Model
    @Published var modelName = "-"
    @Published var modelSize = "-"
    @Published var processor = "-"
    @Published var context = "-"

    // Activity
    @Published var state = "IDLE"
    @Published var activity = "No active generation"
    @Published var elapsed = "-"

    // Prompt
    @Published var promptTokens = "-"
    @Published var promptSpeed = "-"
    @Published var promptProgress: Double = 0

    // Generation
    @Published var generationTokens = "-"
    @Published var generationSpeed = "-"

    // Last activity
    @Published var lastActivity = "Waiting for Ollama..."

    // System metrics
    @Published var systemCPU: Double = 0
    @Published var ollamaCPU: Double = 0
    @Published var memoryUsedGB: Double = 0
    @Published var memoryAvailableGB: Double = 0
    @Published var memoryTotalGB: Double = 0
    @Published var swapUsedGB: Double = 0
    @Published var swapTotalGB: Double = 0
    private var metricsInFlight = false
    private var lastMetricsPoll = Date.distantPast

    private var timer: Timer?
    private var logCursor = LogFileCursor()
    private var requestStart: Date?
    private var lastRequestLogAt: Date?
    private var lastPoll = Date.distantPast
    private var apiRequestGate = PollRequestGate()
    private var apiRequestTask: URLSessionDataTask?
    private var apiRequestToken = PollRequestGeneration()
    private var diagnosticLastLoggedAt: [String: Date] = [:]

    private var logPath: URL {
        AppSettings.shared.expandedLogURL
    }

    init() {
        loadInitialLog()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.scheduledPoll()
            }
        }

        poll()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Poll

    private func refreshSystemMetrics() {
        guard !metricsInFlight else { return }
        metricsInFlight = true

        DispatchQueue.global(qos: .utility).async {
            func run(_ path: String, _ args: [String]) -> String {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return String(data: data, encoding: .utf8) ?? ""
                } catch {
                    return ""
                }
            }

            let top = run("/usr/bin/top", ["-l", "1", "-n", "0"])
            var cpu = 0.0
            if let line = top.components(separatedBy: .newlines)
                .first(where: { $0.contains("CPU usage:") }),
               let range = line.range(of: #"([0-9.]+)% idle"#,
                                      options: .regularExpression) {
                let idleText = line[range]
                    .replacingOccurrences(of: "% idle", with: "")
                cpu = max(0, min(100, 100 - (Double(idleText) ?? 100)))
            }

            let ps = run("/bin/ps", ["-A", "-o", "%cpu=,comm="])
            let ollamaCPU = ps.components(separatedBy: .newlines).compactMap { line -> Double? in
                let lower = line.lowercased()
                guard lower.contains("ollama") || lower.contains("llama-server")
                    || lower.contains("llama.cpp") else { return nil }
                return Double(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
            }.reduce(0, +)

            let total = Double(run("/usr/sbin/sysctl", ["-n", "hw.memsize"])
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let page = Double(run("/usr/sbin/sysctl", ["-n", "hw.pagesize"])
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 4096
            let vm = run("/usr/bin/vm_stat", [])
            func pages(_ label: String) -> Double {
                guard let range = vm.range(of: label) else { return 0 }
                let tail = vm[range.upperBound...]
                return Double(tail.prefix(while: { $0.isNumber })) ?? 0
            }
            let available = (pages("Pages free:") + pages("Pages inactive:")
                + pages("Pages speculative:") + pages("Pages purgeable:")) * page
            let totalGB = total / 1_073_741_824
            let availableGB = min(available / 1_073_741_824, totalGB)

            let swap = run("/usr/sbin/sysctl", ["vm.swapusage"])
            func swapGB(_ key: String) -> Double {
                guard let range = swap.range(
                    of: key + #"\s*=\s*([0-9.]+)\s*([KMG])"#,
                    options: .regularExpression
                ) else { return 0 }
                let fragment = String(swap[range])
                guard let numberRange = fragment.range(of: #"[0-9.]+"#,
                                                       options: .regularExpression),
                      let value = Double(fragment[numberRange]) else { return 0 }
                let unit = fragment.last ?? "M"
                switch unit {
                case "G": return value
                case "K": return value / 1_048_576
                default: return value / 1024
                }
            }
            let usedSwap = swapGB("used")
            let totalSwap = swapGB("total")

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.metricsInFlight = false
                self.systemCPU = cpu
                self.ollamaCPU = ollamaCPU
                self.memoryTotalGB = totalGB
                self.memoryAvailableGB = availableGB
                self.memoryUsedGB = max(0, totalGB - availableGB)
                self.swapUsedGB = usedSwap
                self.swapTotalGB = totalSwap
            }
        }
    }

    private func scheduledPoll() {
        if Date().timeIntervalSince(lastMetricsPoll) >= 3 {
            lastMetricsPoll = Date()
            refreshSystemMetrics()
        }
        let interval = AppSettings.shared.refreshInterval
        guard Date().timeIntervalSince(lastPoll) >= interval else {
            return
        }
        lastPoll = Date()
        poll()
    }

    private func poll() {
        fetchOllama()
        readNewLog()
        updateElapsed()
    }

    private func logDiagnostic(_ key: String, _ message: String) {
        let now = Date()
        guard now.timeIntervalSince(
            diagnosticLastLoggedAt[key] ?? .distantPast
        ) >= 30 else {
            return
        }
        diagnosticLastLoggedAt[key] = now
        NSLog("Ollama Monitor: %@", message)
    }

    // MARK: - Initial Log

    private func loadInitialLog() {

        guard let handle = try? FileHandle(forReadingFrom: logPath) else {
            return
        }

        defer {
            try? handle.close()
        }

        let fileSize = (try? handle.seekToEnd()) ?? 0

        logCursor.advance(to: fileSize)

        if let attributes = try? FileManager.default.attributesOfItem(
            atPath: logPath.path
        ) {
            let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
            logCursor.setInitialPosition(identity: identity, size: fileSize)
        }

        // Only inspect the recent portion of the log.
        let tailSize: UInt64 = 512 * 1024

        if fileSize > tailSize {
            try? handle.seek(toOffset: fileSize - tailSize)
        } else {
            try? handle.seek(toOffset: 0)
        }

        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        for line in text.components(separatedBy: .newlines) {
            processLogLine(line)
        }
    }

    // MARK: - API

    private func fetchOllama() {

        guard !isBusy, unloadingModels.isEmpty else { return }
        guard apiRequestGate.begin() else { return }

        let base = AppSettings.shared.serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+", with: "", options: .regularExpression)

        guard !base.isEmpty,
              let url = URL(string: base + "/api/ps") else {
            apiRequestGate.finish()
            ollamaOnline = false
            monitoringStale = true
            clearLoadedModelDetails()
            logDiagnostic("invalid-server-url", "Invalid Ollama server URL.")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let requestToken = apiRequestToken.advance()

        apiRequestTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in

            guard let self else {
                return
            }

            Task { @MainActor in

                guard self.apiRequestToken.accepts(requestToken) else { return }
                self.apiRequestTask = nil
                self.apiRequestGate.finish()

                guard let data,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {

                    self.ollamaOnline = false
                    self.monitoringStale = true
                    self.clearLoadedModelDetails()
                    if let error {
                        self.logDiagnostic("api-request", "Ollama API request failed: \(error.localizedDescription)")
                    } else if let http = response as? HTTPURLResponse {
                        self.logDiagnostic("api-http", "Ollama API returned HTTP \(http.statusCode).")
                    } else {
                        self.logDiagnostic("api-response", "Ollama API returned no usable response.")
                    }
                    return
                }

                guard let state = OllamaProcessListDecoder.decode(
                    statusCode: http.statusCode,
                    data: data,
                    failed: false
                ) else {
                    self.ollamaOnline = true
                    self.monitoringStale = true
                    self.logDiagnostic("api-decode", "Could not decode Ollama /api/ps response.")
                    return
                }
                guard case let .available(models) = state else { return }

                self.ollamaOnline = true
                self.monitoringStale = false
                self.lastSuccessfulPoll = Date()
                self.loadedModels = models
                self.diagnosticLastLoggedAt.removeValue(forKey: "api-request")
                self.diagnosticLastLoggedAt.removeValue(forKey: "api-http")
                self.diagnosticLastLoggedAt.removeValue(forKey: "api-response")
                self.diagnosticLastLoggedAt.removeValue(forKey: "api-decode")

                if let model = models.first {
                    self.modelName = model.name
                    let gb = Double(model.size) / 1_000_000_000
                    self.modelSize = String(format: "%.1f GB", gb)

                    if model.sizeVRAM > 0 {
                        let vram = Double(model.sizeVRAM) / 1_000_000_000
                        self.processor = String(format: "GPU  %.1f GB VRAM", vram)
                    } else {
                        self.processor = "CPU"
                    }

                    self.context = "\(model.contextLength)"

                } else {
                    self.clearLoadedModelDetails()
                }
            }

        }
        apiRequestTask?.resume()
    }

    private func clearLoadedModelDetails() {
        loadedModels = []
        modelName = "-"
        modelSize = "-"
        processor = "-"
        context = "-"
    }

    func unloadModel(_ model: OllamaLoadedModel) {
        guard !isBusy,
              !unloadingModels.contains(model.name),
              let request = OllamaModelUnloadRequest.make(
                serverURL: AppSettings.shared.serverURL,
                modelName: model.name
              ) else { return }

        unloadingModels.insert(model.name)
        monitoringStale = true
        controlMessage = "Unloading \(model.name)…"
        controlMessageIsError = false
        apiRequestToken.invalidate()
        apiRequestTask?.cancel()
        apiRequestTask = nil
        apiRequestGate.finish()
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.unloadingModels.remove(model.name)
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    let detail = error?.localizedDescription
                        ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                    self.controlMessage = "Could not unload \(model.name): \(detail)"
                    self.controlMessageIsError = true
                    return
                }
                self.controlMessage = "Unloaded \(model.name)."
                self.controlMessageIsError = false
                self.poll()
            }
        }.resume()
    }

    // MARK: - Log

    private func readNewLog() {
        do {
            guard let lines = try logCursor.readAppendedLines(at: logPath) else { return }
            diagnosticLastLoggedAt.removeValue(forKey: "log-stat")
            diagnosticLastLoggedAt.removeValue(forKey: "log-open")
            diagnosticLastLoggedAt.removeValue(forKey: "log-read")
            diagnosticLastLoggedAt.removeValue(forKey: "log-decode")
            for line in lines {
                processLogLine(line)
            }
        } catch LogFileCursorError.invalidUTF8 {
            logDiagnostic("log-decode", "Could not decode appended server log bytes as UTF-8; will retry from the same offset.")
        } catch {
            logDiagnostic("log-read", "Could not read appended server log at \(logPath.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Log Parser

    private func processLogLine(_ line: String) {

        guard !line.isEmpty else {
            return
        }

        let kind = OllamaServerLogParser.classify(line)

        // Ignore the monitor's own API polling.
        if kind == .monitorPoll {
            return
        }

        // Prompt processing
        if kind == .promptProcessing {

            // Start each Ollama request with fresh statistics.
            if requestStart == nil {
                promptProgress = 0
                promptTokens = "-"
                promptSpeed = "-"
                generationTokens = "-"
                generationSpeed = "-"
                elapsed = "-"
                requestStart = Date()
            }

            state = "PROCESSING"
            activity = "Processing context..."
            lastRequestLogAt = Date()

            if promptProgress == 0 {
                generationTokens = "-"
                generationSpeed = "-"
            }

            if let tokens = OllamaServerLogParser.extractNumber(
                after: "n_tokens =",
                from: line
            ) {
                promptTokens = formatNumber(tokens)
            }

            if let progress = OllamaServerLogParser.extractNumber(
                after: "progress =",
                from: line
            ) {

                promptProgress = min(max(progress, 0), 1)

                activity = String(
                    format: "Processing prompt  %.0f%%",
                    progress * 100
                )
            }

            if let speed = OllamaServerLogParser.extractSpeed(from: line) {

                promptSpeed = String(
                    format: "%.1f tok/s",
                    speed
                )
            }

            lastActivity = shortActivity(line)

            return
        }

        // Generation begins
        if kind == .generationStart {

            state = "GENERATING"
            activity = "Generating response..."
            lastRequestLogAt = Date()

            // Prompt progress is no longer meaningful during generation.
            promptProgress = 0

            if requestStart == nil {
                requestStart = Date()
            }

            lastActivity = shortActivity(line)

            return
        }

        // Generation timing
        if kind == .generationTiming {

            state = "GENERATING"
            activity = "Generating response..."
            lastRequestLogAt = Date()

            if let tokens = OllamaServerLogParser.extractNumber(
                after: "n_decoded =",
                from: line
            ) {
                generationTokens = formatNumber(tokens)
            }

            if let speed = OllamaServerLogParser.extractSpeed(from: line) {

                generationSpeed = String(
                    format: "%.1f tok/s",
                    speed
                )
            }

            lastActivity = shortActivity(line)

            return
        }

    // Stop/cancel
        if kind == .stopped {

            lastActivity = shortActivity(line)
            return
        }

        // Idle: debounce briefly so unrelated idle messages cannot
        // hide live generation stats between token updates.
        if kind == .idle {
            let observedActivity = lastRequestLogAt
            lastActivity = shortActivity(line)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self,
                      self.lastRequestLogAt == observedActivity else {
                    return
                }

                self.state = "IDLE"
                self.activity = "No active generation"
                self.requestStart = nil
                self.elapsed = "-"
                self.promptProgress = 0
            }

            return
        }

        // Slot activity
        if kind == .slotActivity {

            lastActivity = shortActivity(line)
        }
    }

    // MARK: - Helpers

    private func formatNumber(_ number: Double) -> String {

        if number >= 1000 {
            return String(
                format: "%.1fk",
                number / 1000
            )
        }

        return String(
            format: "%.0f",
            number
        )
    }

    private func shortActivity(_ line: String) -> String {

        if line.count > 100 {
            return String(line.suffix(100))
        }

        return line
    }

    private func updateElapsed() {

        guard let start = requestStart,
              state != "IDLE" else {
            return
        }

        let seconds = Int(
            Date().timeIntervalSince(start)
        )

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {

            elapsed = String(
                format: "%dh %02dm %02ds",
                hours,
                minutes,
                secs
            )

        } else {

            elapsed = String(
                format: "%dm %02ds",
                minutes,
                secs
            )
        }
    }

    // MARK: - Ollama Controls

    func startOllama() {
        performOllamaControl(.start)
    }

    func stopOllama() {
        performOllamaControl(.stop)
    }

    func restartOllama() {
        performOllamaControl(.restart)
    }

    private enum OllamaControlAction: Equatable {
        case start
        case stop
        case restart

        var planAction: MonitorCore.OllamaControlAction {
            switch self {
            case .start: return .start
            case .stop: return .stop
            case .restart: return .restart
            }
        }

        var progressMessage: String {
            switch self {
            case .start: return "Starting Ollama…"
            case .stop: return "Stopping Ollama…"
            case .restart: return "Restarting Ollama…"
            }
        }
    }

    private func runningOllamaApplicationPID(named appName: String) -> pid_t? {
        NSWorkspace.shared.runningApplications.first { app in
            app.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
        }?.processIdentifier
    }

    private func performOllamaControl(_ action: OllamaControlAction) {
        guard !isBusy else { return }
        isBusy = true
        monitoringStale = true
        controlMessage = action.progressMessage
        controlMessageIsError = false
        apiRequestToken.invalidate()
        apiRequestTask?.cancel()
        apiRequestTask = nil
        apiRequestGate.finish()

        let appName = AppSettings.shared.appDisplayName
        let appPath = AppSettings.shared.appPath
        let serverURL = AppSettings.shared.serverURL
        let appPID = runningOllamaApplicationPID(named: appName)

        DispatchQueue.global(qos: .userInitiated).async {
            var completed = false
            var message = ""
            var resultingOnlineState: Bool?

            do {
                func stopServer() throws {
                    if let appPID {
                        try runControlCommand("/bin/kill", arguments: ["-TERM", "\(appPID)"])
                    } else if ollamaAPIResponds(serverURL: serverURL) {
                        throw ControlCommandFailure(
                            message: "Ollama is online, but its app process could not be found."
                        )
                    }

                }

                func confirmOffline() throws {
                    guard waitForOllama(serverURL: serverURL, online: false) else {
                        throw ControlCommandFailure(
                            message: "Ollama’s API is still responding after 15 seconds."
                        )
                    }
                }

                func launchServer() throws {
                    try runControlCommand("/usr/bin/open", arguments: ["-a", appPath])
                }

                func confirmOnline() throws {
                    guard waitForOllama(serverURL: serverURL, online: true) else {
                        throw ControlCommandFailure(
                            message: "Ollama did not respond within 15 seconds."
                        )
                    }
                }

                if case .start = action,
                   appPID != nil,
                   !ollamaAPIResponds(serverURL: serverURL) {
                        try stopServer()
                        try confirmOffline()
                }

                try OllamaControlPlan.execute(
                    OllamaControlPlan.steps(for: action.planAction)
                ) { step in
                    switch step {
                    case .stop: try stopServer()
                    case .confirmOffline: try confirmOffline()
                    case .pauseBeforeLaunch: Thread.sleep(forTimeInterval: 0.5)
                    case .launch: try launchServer()
                    case .confirmOnline: try confirmOnline()
                    }
                }

                switch action {
                case .start:
                    completed = true
                    resultingOnlineState = true
                    message = "Ollama started and its API is responding."

                case .stop:
                    completed = true
                    resultingOnlineState = false
                    message = "Ollama stopped; its API is offline."

                case .restart:
                    completed = true
                    resultingOnlineState = true
                    message = "Ollama restarted and its API is responding."
                }
            } catch {
                message = error.localizedDescription
            }

            DispatchQueue.main.async {
                self.isBusy = false
                self.controlMessage = message
                self.controlMessageIsError = !completed

                guard completed, let resultingOnlineState else { return }
                self.ollamaOnline = resultingOnlineState
                self.monitoringStale = true

                if !resultingOnlineState {
                    self.clearLoadedModelDetails()
                    self.state = "IDLE"
                    self.activity = "Ollama stopped"
                    self.requestStart = nil
                    self.elapsed = "-"
                    self.promptTokens = "-"
                    self.promptSpeed = "-"
                    self.generationTokens = "-"
                    self.generationSpeed = "-"
                    self.promptProgress = 0
                    self.lastActivity = "Ollama stopped"
                } else if action == .restart {
                    self.clearLoadedModelDetails()
                    self.state = "IDLE"
                    self.activity = "Ollama restarted"
                    self.requestStart = nil
                    self.elapsed = "-"
                    self.lastActivity = "Ollama restarted"
                }
            }
        }
    }
}

// MARK: - UI

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {
    var onHeightChange: ((CGFloat) -> Void)? = nil
    @State private var isSystemPerformanceExpanded = false

    @StateObject private var monitor = Monitor()

    private var statusText: String {
        switch monitor.state {
        case "GENERATING":
            return "Generating response..."
        case "PROCESSING":
            return "Processing prompt..."
        default:
            if monitor.activity == "Ollama restarting..." {
                return monitor.activity
            }
            return monitor.ollamaOnline ? "Idle" : "Ollama offline"
        }
    }

    var body: some View {

        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {

                VStack(alignment: .leading, spacing: 3) {

                    Text("Ollama Monitor")
                        .font(.title2)
                        .bold()

                    HStack(spacing: 6) {

                        Circle()
                            .fill(
                                monitor.ollamaOnline
                                ? Color.green
                                : Color.red
                            )
                            .frame(
                                width: 8,
                                height: 8
                            )

                        Text(
                            monitor.ollamaOnline
                            ? "Ollama Online"
                            : "Ollama Offline"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if monitor.isBusy {

                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Model
            VStack(alignment: .leading, spacing: 5) {

                Text(monitor.modelName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 12) {
                    Text("Context: \(monitor.context)")
                    Text("Model: \(monitor.modelSize)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                if monitor.loadedModels.count > 1 {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(monitor.loadedModels) { model in
                            HStack(spacing: 8) {
                                Text("\(model.name) · \(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Button(monitor.unloadingModels.contains(model.name) ? "Unloading…" : "Unload") {
                                    monitor.unloadModel(model)
                                }
                                .disabled(!monitor.ollamaOnline || monitor.isBusy || monitor.unloadingModels.contains(model.name))
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 4)
                } else if let model = monitor.loadedModels.first {
                    HStack {
                        Spacer()
                        Button(monitor.unloadingModels.contains(model.name) ? "Unloading…" : "Unload model") {
                            monitor.unloadModel(model)
                        }
                        .font(.caption)
                        .disabled(!monitor.ollamaOnline || monitor.isBusy || monitor.unloadingModels.contains(model.name))
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Activity
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("ACTIVITY")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.16))

                        if monitor.state == "PROCESSING" {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.orange)
                                .frame(
                                    width: geometry.size.width *
                                        min(max(monitor.promptProgress, 0), 1)
                                )
                        }

                        if monitor.state == "GENERATING" {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(.green)
                                .frame(
                                    width: max(geometry.size.width - 8, 0),
                                    height: 4
                                )
                                .position(
                                    x: geometry.size.width / 2,
                                    y: geometry.size.height - 4
                                )
                        }

                        Text(
                            monitor.state == "PROCESSING"
                                ? String(format: "Processing prompt %.0f%%",
                                         min(max(monitor.promptProgress, 0), 1) * 100)
                                : monitor.state == "GENERATING"
                                    ? "Generating response..."
                                    : "Last generation"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 24)

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monitor.state == "PROCESSING" ? "PROMPT TOKENS" : "GENERATED")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(monitor.state == "PROCESSING"
                             ? monitor.promptTokens : monitor.generationTokens)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(monitor.state == "PROCESSING" ? "PROMPT SPEED" : "GENERATION SPEED")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(monitor.state == "PROCESSING"
                             ? monitor.promptSpeed : monitor.generationSpeed)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("ELAPSED")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(monitor.elapsed)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
            }

            Divider().padding(.vertical, 8)

            // System Performance
            Button {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    isSystemPerformanceExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("SYSTEM PERFORMANCE")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: isSystemPerformanceExpanded
                          ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("System Performance")
            .accessibilityHint(
                isSystemPerformanceExpanded
                    ? "Collapse system performance details"
                    : "Expand system performance details"
            )

            if isSystemPerformanceExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    metricRow(
                        title: "CPU",
                        value: String(format: "%.0f%%", monitor.systemCPU),
                        fraction: monitor.systemCPU / 100,
                        color: .blue
                    )

                    metricRow(
                        title: "OLLAMA CPU",
                        value: String(format: "%.1f%%", monitor.ollamaCPU),
                        fraction: min(monitor.ollamaCPU / 100, 1),
                        color: .green
                    )

                    HStack {
                        Text("VRAM")
                            .font(.caption2)
                            .bold()
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(
                            monitor.processor.replacingOccurrences(
                                of: "GPU  ",
                                with: ""
                            )
                        )
                        .font(.system(
                            size: 11,
                            weight: .medium,
                            design: .monospaced
                        ))
                    }

                    metricRow(
                        title: "MEMORY",
                        value: monitor.memoryTotalGB > 0
                            ? String(
                                format: "%.1f / %.0f GB used",
                                monitor.memoryUsedGB,
                                monitor.memoryTotalGB
                            )
                            : "Collecting...",
                        fraction: monitor.memoryTotalGB > 0
                            ? monitor.memoryUsedGB / monitor.memoryTotalGB : 0,
                        color: monitor.memoryTotalGB > 0 &&
                            monitor.memoryAvailableGB / monitor.memoryTotalGB < 0.15
                            ? .orange : .blue
                    )

                    HStack {
                        Text("Available (est.)")
                        Spacer()
                        Text(String(format: "%.1f GB", monitor.memoryAvailableGB))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    metricRow(
                        title: "SWAP",
                        value: monitor.swapTotalGB > 0
                            ? String(
                                format: "%.1f / %.1f GB",
                                monitor.swapUsedGB,
                                monitor.swapTotalGB
                            )
                            : "0 GB used",
                        fraction: monitor.swapTotalGB > 0
                            ? monitor.swapUsedGB / monitor.swapTotalGB : 0,
                        color: monitor.swapUsedGB >= 2 ? .orange : .secondary
                    )

                    Text("Available memory is estimated from macOS VM statistics. GPU utilization is not available from this monitor.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().padding(.vertical, 8)

            // Controls
            // Controls
            VStack(alignment: .leading, spacing: 6) {

                Text("OLLAMA")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {

                    Button {
                        monitor.startOllama()
                    } label: {

                        Label(
                            "Start",
                            systemImage: "play.fill"
                        )
                        .font(.caption)
                        .frame(
                            maxWidth: .infinity
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.green.opacity(0.15))
                    .disabled(
                        monitor.ollamaOnline ||
                        monitor.isBusy || !monitor.unloadingModels.isEmpty
                    )

                    Button {
                        monitor.stopOllama()
                    } label: {

                        Label(
                            "Stop",
                            systemImage: "stop.fill"
                        )
                        .font(.caption)
                        .frame(
                            maxWidth: .infinity
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.red.opacity(0.15))
                    .disabled(
                        !monitor.ollamaOnline ||
                        monitor.isBusy || !monitor.unloadingModels.isEmpty
                    )

                    Button {
                        monitor.restartOllama()
                    } label: {

                        Label(
                            "Restart",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                        .frame(
                            maxWidth: .infinity
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !monitor.ollamaOnline ||
                        monitor.isBusy || !monitor.unloadingModels.isEmpty
                    )
                }
                .controlSize(.small)

                if !monitor.controlMessage.isEmpty {
                    Text(monitor.controlMessage)
                        .font(.caption)
                        .foregroundStyle(
                            monitor.controlMessageIsError ? Color.red : Color.secondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ollama-control-status")
                }
            }

            Spacer()

            // Footer
            VStack(spacing: 5) {
                HStack {
                    Text("Status")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let lastSuccessfulPoll = monitor.lastSuccessfulPoll {
                    Text(monitor.monitoringStale
                         ? "Stale · last update \(lastSuccessfulPoll, style: .time)"
                         : "Updated \(lastSuccessfulPoll, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(monitor.monitoringStale ? Color.orange : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                HStack {
                    Text("Last activity")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(monitor.lastActivity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
        .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
            onHeightChange?(height)
        }
    }

    private func metricRow(
        title: String,
        value: String,
        fraction: Double,
        color: Color
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width *
                               min(max(fraction, 0), 1))
                }
            }
            .frame(height: 5)
        }
    }

    private func stat(
        title: String,
        value: String
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 3
        ) {

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(
                    size: 14,
                    weight: .medium,
                    design: .monospaced
                ))
        }
    }
}


// MARK: - Settings Window

@MainActor
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Ollama server URL", text: $settings.serverURL)
                TextField("Server log path", text: $settings.logPath)
                TextField("Ollama app name or path", text: $settings.appPath)

                Picker("Refresh interval", selection: $settings.refreshInterval) {
                    Text("0.5 seconds").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                }
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    settings.restoreDefaults()
                }
            }

            Text("Changes are saved automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - About Window

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Ollama Monitor")
                .font(.title2)
                .bold()

            Text("Version 0.28")
                .foregroundStyle(.secondary)

            Text("David Lomneck")
            Text("Copyright © 2026 David Lomneck")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 340, height: 240)
    }
}

// MARK: - Native Menu Bar App

extension Notification.Name {
    static let ollamaMonitorShowSettings =
        Notification.Name("OllamaMonitorShowSettings")
    static let ollamaMonitorShowAbout =
        Notification.Name("OllamaMonitorShowAbout")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var dashboardPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "cpu",
                accessibilityDescription: "Ollama Monitor"
            )
            button.toolTip = "Ollama Monitor"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsFromNotification(_:)),
            name: .ollamaMonitorShowSettings,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showAboutFromNotification(_:)),
            name: .ollamaMonitorShowAbout,
            object: nil
        )
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: button)
        } else {
            toggleDashboard()
        }
    }

    private func showContextMenu(from button: NSButton) {
        let menu = NSMenu()

        let settings = NSMenuItem(
            title: "Settings",
            action: #selector(showSettings(_:)),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(
            title: "About Ollama Monitor",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp(_:)),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height),
            in: button
        )
    }

    private func toggleDashboard() {
        if let panel = dashboardPanel, panel.isVisible {
            panel.orderOut(nil)
            return
        }

        let panel: NSPanel

        if let existing = dashboardPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(
                    x: 0, y: 0, width: 380, height: 800
                ),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false
            )

            panel.title = "Ollama Monitor"
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary
            ]
            panel.contentViewController = NSHostingController(
                rootView: ContentView { [weak panel] height in
                    guard let panel, height > 0 else {
                        return
                    }

                    let currentHeight = panel.contentView?.bounds.height ?? 0
                    guard abs(currentHeight - height) > 1 else {
                        return
                    }

                    let oldFrame = panel.frame
                    let newSize = NSSize(width: 380, height: height)
                    let heightDelta = newSize.height - oldFrame.size.height

                    var newFrame = oldFrame
                    newFrame.size = newSize
                    newFrame.origin.y -= heightDelta

                    panel.setFrame(newFrame, display: true, animate: false)
                }
            )

            dashboardPanel = panel
        }

        positionDashboard(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionDashboard(_ panel: NSPanel) {
        guard
            let button = statusItem.button,
            let buttonWindow = button.window,
            let screen = buttonWindow.screen
        else {
            panel.center()
            return
        }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let visible = screen.visibleFrame
        let frame = panel.frame

        let x = min(
            max(screenRect.midX - frame.width / 2, visible.minX),
            visible.maxX - frame.width
        )

        let y = max(
            visible.minY,
            screenRect.minY - frame.height - 6
        )

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func showSettingsFromNotification(
        _ notification: Notification
    ) {
        showSettings(nil)
    }

    @objc private func showAboutFromNotification(
        _ notification: Notification
    ) {
        showAbout(nil)
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0, width: 440, height: 300
                ),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Ollama Monitor Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView()
            )
            settingsWindow = window
        }

        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout(_ sender: Any?) {
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0, width: 340, height: 240
                ),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "About Ollama Monitor"
            window.level = .modalPanel
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: AboutView()
            )
            aboutWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

@main
struct OllamaMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
