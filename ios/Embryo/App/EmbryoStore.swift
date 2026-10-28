import Foundation
import SwiftUI

@MainActor
@Observable
final class EmbryoStore {
    static let defaultEndpoint = "http://dsw-evergreen.tail1c6dfa.ts.net:8090"
    var endpoint = defaultEndpoint
    var hasToken = false
    var connection = "Not connected"
    var connectionError: String?
    private var connectionDiagnostic: String?
    var checking = false
    var connected = false
    var models: [String] = ["qwen35-4b-rl-v3c80", "qwen35-4b-native"]
    var images: [String: ImageDescriptor] = [:]
    var sandboxCount: Int?
    var records: [RunRecord] = []
    var visibleRunIDs: [UUID] = []
    var prompt = "I finally finished a difficult project. What would you say to me?"
    var selectedModel = "qwen35-4b-native"
    var comparisonModel = "qwen35-4b-steered"
    var chatMode = true
    private var chatMessages: [String: [ChatMessage]] = [:]
    var selectedImage = "science-py312"
    var maxSteps = 100
    var compare = true
    var loadingHistory = false
    var historyError: String?
    var historyTotal = 0
    var historyLimit = 30
    var persistenceError: String?
    var actionError: String?
    var selectedTab = 0
    let isDemo: Bool
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private var connectionRevision = 0
    private var developmentSmokeStarted = false

    var activeCount: Int { jobs.count }
    var imageKeys: [String] {
        images.keys.sorted { lhs, rhs in
            if lhs.hasPrefix("science-") != rhs.hasPrefix("science-") { return lhs.hasPrefix("science-") }
            return lhs < rhs
        }
    }
    var canRun: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf8.count <= 32768 && (isDemo || (connected && (chatMode || images[selectedImage] != nil))) && activeCount == 0 && models.contains(selectedModel) && (!compare || (models.contains(comparisonModel) && comparisonModel != selectedModel)) }
    private var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Embryo", isDirectory: true).appendingPathComponent("library.json")
    }
    struct Library: Codable { var version = 1; var endpoint: String; var records: [RunRecord] }

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if isDemo { configureDemo(); return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent().deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                let saved = try JSONDecoder().decode(Library.self, from: Data(contentsOf: storageURL))
                endpoint = saved.endpoint; records = saved.records
                for index in records.indices where records[index].active {
                    records[index].status = "interrupted"; records[index].finished = Date()
                    records[index].error = "The app closed before a final event. Refresh history for the server’s saved result, or re-run as a new experiment."
                }
            }
        } catch { persistenceError = error.localizedDescription }
        // Tailscale identity replaces client-held gateway credentials.
        try? TokenVault.remove()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--live-test") {
            prompt = "Embryo iPhone connection smoke test. Use bash once to run python -c 'print(17*23)'. Then state the numeric result and finish. Do not run additional commands."
            maxSteps = 3
            chatMode = false; compare = false
        }
        if ProcessInfo.processInfo.arguments.contains("--steering-smoke") {
            prompt = "I finally finished a difficult project. Reply in one short sentence."
            chatMode = true; compare = true
        }
        #endif
        writeDevelopmentVerification()
    }

    private func writeDevelopmentVerification() {
        #if DEBUG
        DevelopmentVerification.writeConnection(connected: connected, hasToken: hasToken, models: models, imageCount: images.count, error: connectionError, diagnostic: connectionDiagnostic)
        #endif
    }

    func runDevelopmentSmokeIfRequested() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard (arguments.contains("--live-test") || arguments.contains("--steering-smoke")), arguments.contains("--verify-live-run"),
              connected, !developmentSmokeStarted else { return }
        developmentSmokeStarted = true
        start()
        #endif
    }

    func saveConnection(endpoint value: String) async {
        guard activeCount == 0 else { actionError = "Finish or cancel active runs before changing the connection."; return }
        do {
            let parsed = try EmbryoEndpoint(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines))
            endpoint = parsed.rawValue
            connected = false; connectionRevision += 1; persist()
            await checkConnection()
        } catch { connectionError = error.localizedDescription; connected = false }
    }

    private func credentials() throws -> (EmbryoClient, String) {
        (EmbryoClient(endpoint: try EmbryoEndpoint(rawValue: endpoint)), "")
    }

    func checkConnection() async {
        guard !isDemo else { return }
        guard !checking else { return }
        checking = true; connection = "Checking…"; connectionError = nil; connectionDiagnostic = nil
        let revision = connectionRevision
        defer { checking = false; writeDevelopmentVerification() }
        do {
            let (client, token) = try credentials()
            async let health = client.health(token: token)
            async let imageList = client.images(token: token)
            async let modelList = client.models(token: token)
            let (h, i, m) = try await (health, imageList, modelList)
            guard revision == connectionRevision else { return }
            guard h.ok else { throw AppError.message("The gateway is not ready. Try again shortly.") }
            models = m.map(\.id); images = i; sandboxCount = h.sandboxes
            if !models.contains(selectedModel), let first = models.first { selectedModel = first }
            if !models.contains(comparisonModel) || comparisonModel == selectedModel {
                comparisonModel = models.first(where: { $0 != selectedModel }) ?? selectedModel
            }
            if images[selectedImage] == nil, let first = imageKeys.first { selectedImage = first }
            connected = true; connection = "Gateway connected"
        } catch {
            guard revision == connectionRevision else { return }
            connected = false; connection = "Connection unavailable"; connectionError = error.localizedDescription
            let nsError = error as NSError
            connectionDiagnostic = "\(nsError.domain) code=\(nsError.code)"
            if let known = error as? GatewayError { connectionDiagnostic = "Gateway: \(known.localizedDescription)" }
        }
    }

    func start() {
        guard canRun else { actionError = "Connect to the gateway, choose an available sandbox, and enter a task (at most 32 KB)."; return }
        let arms = compare ? [selectedModel, comparisonModel] : [selectedModel]
        guard arms.allSatisfy({ models.contains($0) }) else { actionError = "Select two available models to compare."; return }
        let pair = compare ? UUID() : nil
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleRunIDs = []
        for model in arms {
            var record = RunRecord(model: model, image: chatMode ? "chat" : selectedImage, task: task, maxSteps: chatMode ? 1 : maxSteps, comparisonID: pair)
            record.isSample = isDemo
            records.insert(record, at: 0); visibleRunIDs.append(record.id)
            if chatMode && !isDemo { launchChat(record) } else { launch(record) }
        }
        persist()
    }

    func newChat() {
        guard activeCount == 0 else { return }
        chatMessages = [:]; visibleRunIDs = []
    }

    private func launchChat(_ record: RunRecord) {
        let id = record.id
        let messages = (chatMessages[record.model] ?? []) + [ChatMessage(role: "user", content: record.task)]
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.jobs.removeValue(forKey: id); self.persist() }
            do {
                let (client, token) = try self.credentials()
                self.update(id) { $0.status = "running"; $0.steps = [TrajectoryStep(id: 0, text: "", tools: [])] }
                var answer = ""
                var finishReason: String?
                for try await chunk in client.chat(ChatRequest(model: record.model, messages: messages), token: token) {
                    try Task.checkCancellation()
                    answer += chunk.choices.first?.delta.content ?? ""
                    finishReason = chunk.choices.first?.finish_reason ?? finishReason
                    self.update(id) { r in
                        r.steps[0].text = answer
                        if let usage = chunk.usage { r.steps[0].usage = usage }
                    }
                }
                try Task.checkCancellation()
                self.chatMessages[record.model] = messages + [ChatMessage(role: "assistant", content: answer)]
                self.update(id) { r in r.status = finishReason == "length" ? "token_limit" : "finished"; r.finished = Date() }
            } catch {
                self.update(id) { r in
                    guard r.active else { return }
                    r.status = Task.isCancelled ? "cancelled" : "interrupted"; r.finished = Date(); r.error = error.localizedDescription
                }
            }
        }
    }

    private func launch(_ record: RunRecord) {
        let id = record.id
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.jobs.removeValue(forKey: id); self.persist() }
            if self.isDemo {
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                self.update(id) { r in
                    r.status = "finished"; r.finished = Date(); r.steps = Self.sampleSteps
                }
                return
            }
            do {
                let (client, token) = try self.credentials()
                let request = StartRunRequest(model: record.model, image: record.image, task: record.task, maxSteps: record.maxSteps)
                for try await event in client.startRun(request, token: token) {
                    try Task.checkCancellation()
                    self.update(id) { $0.apply(event) }
                }
                self.update(id) { r in
                    if r.active {
                        r.status = "interrupted"; r.finished = Date()
                        r.error = "The stream ended without a final result. Refresh history, or re-run as a new experiment."
                    }
                }
            } catch {
                self.update(id) { r in
                    guard r.active else { return }
                    r.status = Task.isCancelled ? "cancelled" : "interrupted"
                    r.finished = Date(); r.error = Task.isCancelled ? "Stream closed. The server stops the run when it detects the disconnect." : error.localizedDescription
                }
            }
        }
    }

    func cancel(_ id: UUID, background: Bool = false) {
        jobs[id]?.cancel()
        update(id) { r in
            guard r.active else { return }
            r.status = "cancelled"; r.finished = Date()
            r.error = background ? "The app went into the background and closed this stream. Refresh history for the server’s final status, or re-run." : "Stream closed. Server cleanup follows when the disconnect is detected; model generation or the current command may finish first."
        }
        persist()
    }
    func cancelForBackground() { for id in Array(jobs.keys) { cancel(id, background: true) }; persist() }
    func record(_ id: UUID) -> RunRecord? { records.first { $0.id == id } }
    func update(_ id: UUID, _ change: (inout RunRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index]); scheduleSave()
    }
    func rerun(_ id: UUID) {
        guard let r = record(id) else { return }
        prompt = r.task; selectedModel = r.model; selectedImage = r.image; maxSteps = r.maxSteps; compare = false
        chatMode = r.image == "chat"
        selectedTab = 0; visibleRunIDs = []
    }
    func useTemplate(_ template: TaskTemplate) {
        prompt = template.text
        if !template.image.isEmpty { selectedImage = template.image }
    }

    func refreshHistory() async {
        guard !isDemo, !loadingHistory else { return }
        loadingHistory = true; historyError = nil
        defer { loadingHistory = false; persist() }
        do {
            let (client, token) = try credentials()
            let ids = try await client.runIDs(token: token).sorted(by: >)
            historyTotal = ids.count
            for id in ids.prefix(historyLimit) {
                try Task.checkCancellation()
                if records.contains(where: { $0.remoteID == id && $0.active }) { continue }
                do {
                    let detail = try await client.run(id: id, token: token)
                    if let index = records.firstIndex(where: { $0.remoteID == id }) {
                        records[index].reconcile(server: detail)
                    } else { records.append(RunRecord(server: detail)) }
                } catch { historyError = "Some transcripts could not be loaded: \(error.localizedDescription)" }
            }
            records.sort { $0.started > $1.started }
        } catch { historyError = error.localizedDescription }
    }

    func export(_ selected: [RunRecord]) throws -> URL {
        struct Export: Encodable {
            let schema = "embryo.runs.v1"
            let exportedAt = Date()
            let endpoint: String
            let metricNotes = "Token usage is the sum of per-step API usage; input tokens include repeated context. Missing usage is unknown. Finished means the agent stopped, not verified success. Labels are user judgments."
            let runs: [RunRecord]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmbryoExports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("embryo-\(UUID().uuidString.prefix(8)).json")
        try encoder.encode(Export(endpoint: endpoint, runs: selected)).write(to: path, options: [.atomic, .completeFileProtection])
        return path
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.persist()
        }
    }
    func persist() {
        guard !isDemo else { return }
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let data = try JSONEncoder().encode(Library(endpoint: endpoint, records: records))
            try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
            persistenceError = nil
        } catch { persistenceError = "Local save failed: \(error.localizedDescription)" }
    }

    private func configureDemo() {
        chatMode = false; compare = false; comparisonModel = "qwen35-4b-rl-v3c80"
        connection = "Offline sample"; connected = false
        images = ["science-py312": ImageDescriptor(cwd: "/tmp", note: "Python 3.12 · NumPy, SciPy, pandas, scikit-learn"), "science-py38-torch": ImageDescriptor(cwd: "/tmp", note: "Python 3.8 · SymPy, PyTorch")]
        var sample = RunRecord(model: models[0], image: "science-py312", task: "Verify the variance of a sample mean with a reproducible simulation.", maxSteps: 100)
        sample.isSample = true; sample.status = "finished"; sample.started = Date().addingTimeInterval(-18); sample.finished = Date()
        sample.steps = Self.sampleSteps; records = [sample]
    }
    static var sampleSteps: [TrajectoryStep] {
        [TrajectoryStep(id: 0, text: "I’ll test the prediction with a fixed seed, then compare empirical variance to 1/n.", tools: [ToolTrace(id: "sample-tool", name: "bash", command: "python - <<'PY'\nimport numpy as np\nrng = np.random.default_rng(42)\nfor n in (10, 100, 1000):\n    means = rng.normal(size=(10000, n)).mean(axis=1)\n    print(n, means.var(), 1/n)\nPY", observation: "10    0.1020    0.1000\n100   0.0097    0.0100\n1000  0.0010    0.0010\n\nTool metadata: {'returncode': 0}")], usage: TokenUsage(promptTokens: 420, completionTokens: 156, totalTokens: 576)),
         TrajectoryStep(id: 1, text: "The empirical variance is close to 1/n at each sample size. This is a numerical check; sampling noise explains the small deviations.\n\nThis is an illustrative offline transcript, not a live model result.", tools: [], usage: TokenUsage(promptTokens: 640, completionTokens: 75, totalTokens: 715))]
    }
    enum AppError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let text) = self { return text }; return nil } }
}
