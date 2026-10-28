import SwiftUI
import UniformTypeIdentifiers

struct RunLane: View {
    @Environment(EmbryoStore.self) private var store
    let id: UUID
    var compact = false
    @State private var detail = false
    var body: some View {
        if let run = store.record(id) {
            VStack(alignment: .leading, spacing: 14) {
                Surface {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(modelTitle(run.model)).font(.headline)
                            Text(run.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if run.active { ProgressView().controlSize(.small) }
                    }
                    CapsuleLabel(text: run.statusTitle, color: run.status == "finished" ? EmbryoStyle.green : run.active ? .blue : .orange)
                    RunMetrics(run: run)
                    HStack {
                        if run.active {
                            Button(role: .destructive) { store.cancel(id) } label: { Label("Cancel", systemImage: "stop.circle") }
                        } else {
                            Button { detail = true } label: { Label("Review & label", systemImage: "tag") }
                            Spacer()
                            Button { store.rerun(id) } label: { Image(systemName: "arrow.counterclockwise") }.accessibilityLabel("Reuse task")
                        }
                    }.font(.subheadline.weight(.semibold))
                    if let error = run.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                if run.steps.isEmpty {
                    Surface {
                        Label(run.active ? "Preparing the experiment…" : "No steps received", systemImage: "ellipsis.message")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if run.active { Text("The sandbox and model may take a moment. Keep Embryo in the foreground.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                ForEach(run.steps) { step in StepCard(step: step) }
            }.sheet(isPresented: $detail) { NavigationStack { RunDetailView(id: id).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { detail = false } } } } }
        }
    }
}

struct RunMetrics: View {
    let run: RunRecord
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(alignment: .top, spacing: 12) {
                metric("Steps", "\(run.steps.count)/\(run.maxSteps)")
                Spacer(minLength: 0)
                metric("Output tokens", run.outputTokens?.formatted() ?? "—")
                Spacer(minLength: 0)
                metric("Elapsed", durationText(run.elapsed))
            }
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(value).font(.system(.subheadline, design: .monospaced).weight(.semibold)); Text(title).font(.caption2).foregroundStyle(.secondary) }
    }
}

struct StepCard: View {
    let step: TrajectoryStep
    var body: some View {
        Surface {
            HStack {
                Text(String(format: "%02d", step.id + 1)).font(.caption.monospaced().weight(.bold)).foregroundStyle(EmbryoStyle.green)
                Text("Agent").font(.subheadline.weight(.semibold))
                Spacer()
                if let usage = step.usage { Text("\(usage.completionTokens.formatted()) out").font(.caption2.monospaced()).foregroundStyle(.secondary) }
            }
            if !step.text.isEmpty { Text(step.text).font(.subheadline).lineSpacing(4).textSelection(.enabled) }
            ForEach(step.tools) { tool in ToolCard(tool: tool) }
        }
    }
}

struct ToolCard: View {
    let tool: ToolTrace
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tool.name, systemImage: "terminal").font(.caption.weight(.semibold))
                Spacer()
                if let code = tool.returnCode { CapsuleLabel(text: "exit \(code)", color: code == 0 ? EmbryoStyle.green : .orange) }
                else if tool.observation == nil { Text("Waiting").font(.caption2).foregroundStyle(.secondary) }
            }
            if !tool.command.isEmpty {
                ScrollView(.horizontal) { Text(highlightedCommand(tool.command)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(12) }
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            if let observation = tool.observation {
                if tool.truncated { Label("Server truncated this observation", systemImage: "scissors").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(observation).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }.frame(maxHeight: 320)
                } label: {
                    Text(expanded ? "Observation" : "Observation · \(observation.count.formatted()) characters").font(.caption.weight(.medium))
                }
            }
        }
    }
    private func highlightedCommand(_ command: String) -> AttributedString {
        var result = AttributedString(command)
        // Minimal shell syntax highlighting; commands remain selectable verbatim.
        for pattern in [#"(?m)^\s*#.*$"#, #"'[^']*'|\"[^\"]*\""#, #"\b(python3?|import|from|for|in|print|if|then|fi|echo|cd|pytest|pip)\b"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: command, range: NSRange(command.startIndex..., in: command)) {
                if let range = Range(match.range, in: command), let attributedRange = Range(range, in: result) { result[attributedRange].foregroundColor = EmbryoStyle.green }
            }
        }
        return result
    }
}

struct RunDetailView: View {
    @Environment(EmbryoStore.self) private var store
    let id: UUID
    @State private var exportURL: URL?
    @State private var sharing = false
    var body: some View {
        if let run = store.record(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Surface {
                        HStack { Text(modelTitle(run.model)).font(.headline); Spacer(); CapsuleLabel(text: run.statusTitle) }
                        if run.isSample { CapsuleLabel(text: "Illustrative offline sample", color: .orange) }
                        Text(run.task).font(.subheadline).textSelection(.enabled)
                        RunMetrics(run: run)
                        Text("Total tokens: \(run.totalTokens.map { $0.formatted() } ?? "unavailable") · Includes repeated input context.").font(.caption).foregroundStyle(.secondary)
                        Text("Finished means the agent stopped. Your label records whether the task was actually solved.").font(.caption).foregroundStyle(.secondary)
                        if let error = run.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        if let remote = run.remoteID { Text(remote).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                        HStack {
                            Button("Reuse task", systemImage: "arrow.counterclockwise") { store.rerun(id) }
                            Spacer()
                            Button("Export JSON", systemImage: "square.and.arrow.up") {
                                do { exportURL = try store.export([run]); sharing = true } catch { store.actionError = error.localizedDescription }
                            }.accessibilityIdentifier("run.export")
                        }.font(.subheadline)
                    }
                    Surface {
                        Label("Your assessment", systemImage: "tag").font(.headline)
                        Picker("Outcome", selection: annotationBinding(\.label, fallback: "Unrated")) {
                            ForEach(RunAnnotation.labels, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("annotation.label")
                        FlowTags(selected: run.annotation.failureModes) { mode in
                            store.update(id) { r in
                                if r.annotation.failureModes.contains(mode) { r.annotation.failureModes.removeAll { $0 == mode } }
                                else { r.annotation.failureModes.append(mode) }
                            }
                        }
                        TextField("Notes, checks, and failure cases", text: annotationBinding(\.notes, fallback: ""), axis: .vertical)
                            .lineLimit(3...8).font(.subheadline).accessibilityIdentifier("annotation.notes")
                        Text("Labels stay on this device and are included in JSON exports.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(run.steps) { step in StepCard(step: step) }
                }.padding(18).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }.background(EmbryoStyle.paper).navigationTitle("Run review").navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $sharing) { if let exportURL { ShareSheet(url: exportURL) } }
                .onDisappear { store.persist() }
        } else { ContentUnavailableView("Run unavailable", systemImage: "doc.questionmark") }
    }
    private func annotationBinding<T>(_ key: WritableKeyPath<RunAnnotation, T>, fallback: T) -> Binding<T> {
        Binding(get: { store.record(id)?.annotation[keyPath: key] ?? fallback }, set: { value in store.update(id) { $0.annotation[keyPath: key] = value } })
    }
}

struct FlowTags: View {
    var selected: [String]
    var toggle: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 9) {
            ForEach(RunAnnotation.modes, id: \.self) { mode in
                Button { toggle(mode) } label: {
                    HStack(spacing: 4) { if selected.contains(mode) { Image(systemName: "checkmark") }; Text(mode) }
                        .font(.caption).padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(selected.contains(mode) ? EmbryoStyle.green : .secondary)
                        .background(selected.contains(mode) ? EmbryoStyle.green.opacity(0.1) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
