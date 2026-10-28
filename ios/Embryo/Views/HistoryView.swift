import SwiftUI

struct HistoryView: View {
    @Environment(EmbryoStore.self) private var store
    @State private var search = ""
    @State private var model = "All"
    @State private var image = "All"
    @State private var status = "All"
    @State private var label = "All"
    @State private var exportURL: URL?
    @State private var sharing = false
    private var filtered: [RunRecord] {
        store.records.filter { record in
            (model == "All" || record.model == model) && (image == "All" || record.image == image) &&
            (status == "All" || record.status == status) && (label == "All" || record.annotation.label == label) &&
            (search.isEmpty || "\(record.task) \(record.model) \(record.image) \(record.annotation.notes) \(record.remoteID ?? "")".localizedCaseInsensitiveContains(search))
        }.sorted { $0.started > $1.started }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            filter("Model", selection: $model, values: Array(Set(store.records.map(\.model))).sorted())
                            filter("Sandbox", selection: $image, values: Array(Set(store.records.map(\.image))).sorted())
                            filter("Status", selection: $status, values: Array(Set(store.records.map(\.status))).sorted())
                            filter("Label", selection: $label, values: RunAnnotation.labels)
                        }.padding(.vertical, 3)
                    }.scrollIndicators(.hidden)
                    if store.loadingHistory { ProgressView("Loading saved transcripts…") }
                    if let error = store.historyError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    Text("\(filtered.count) shown · \(store.records.count) on device\(store.historyTotal > 0 ? " · \(store.historyTotal) on server" : "")").font(.caption).foregroundStyle(.secondary)
                }
                if filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "An open notebook" : "No matching runs", systemImage: "book.closed", description: Text(search.isEmpty ? "Run an experiment, or refresh to retrieve saved server transcripts." : "Try another search or clear your filters."))
                }
                ForEach(filtered) { run in
                    NavigationLink { RunDetailView(id: run.id) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(run.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            HStack { Text(modelTitle(run.model)); Spacer(); Text(run.started, style: .date) }.font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                CapsuleLabel(text: run.statusTitle)
                                if run.annotation.label != "Unrated" { CapsuleLabel(text: run.annotation.label, color: .indigo) }
                                if run.isSample { CapsuleLabel(text: "Sample", color: .orange) }
                                Spacer()
                                Text("\(run.steps.count) steps").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7)
                    }
                }
                if store.historyTotal > store.historyLimit {
                    Button("Load 30 more server transcripts") { store.historyLimit += 30; Task { await store.refreshHistory() } }.disabled(store.loadingHistory)
                }
                Section {
                    Text("Search and filters apply to transcripts loaded on this device. Server history supplies messages; token metrics are available only when captured live. Exports include your labels, raw events, and saved server records when available.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("History").searchable(text: $search, prompt: "Tasks, notes, models, run IDs")
                .refreshable { await store.refreshHistory() }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refreshHistory() } }.disabled(store.loadingHistory || (!store.hasToken && !store.isDemo))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Export shown", systemImage: "square.and.arrow.up") {
                            do { exportURL = try store.export(filtered); sharing = true } catch { store.actionError = error.localizedDescription }
                        }.disabled(filtered.isEmpty)
                    }
                }
                .sheet(isPresented: $sharing) { if let exportURL { ShareSheet(url: exportURL) } }
        }
    }
    private func filter(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        Menu {
            Picker(title, selection: selection) { Text("All").tag("All"); ForEach(values, id: \.self) { Text($0).tag($0) } }
        } label: {
            HStack(spacing: 5) { Text(selection.wrappedValue == "All" ? title : selection.wrappedValue).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }
                .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 8)
                .background(EmbryoStyle.green.opacity(0.08), in: Capsule())
        }
    }
}
