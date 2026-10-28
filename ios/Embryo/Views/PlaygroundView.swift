import SwiftUI

struct PlaygroundView: View {
    @Environment(EmbryoStore.self) private var store
    @State private var imagePicker = false
    @State private var detailID: UUID?
    @FocusState private var editing: Bool
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if !store.connected && !store.isDemo { connectionCard }
                    Picker("Mode", selection: $store.chatMode) {
                        Text("Chat").tag(true)
                        Text("Agent in sandbox").tag(false)
                    }.pickerStyle(.segmented).disabled(store.activeCount > 0)
                    Surface {
                        HStack {
                            Label("Your experiment", systemImage: "flask").font(.headline)
                            Spacer()
                            Menu {
                                ForEach(TaskTemplate.all) { template in
                                    Button { store.useTemplate(template) } label: { Label(template.id, systemImage: template.symbol) }
                                }
                            } label: { Label("Templates", systemImage: "square.stack").font(.subheadline) }
                        }
                        TextEditor(text: $store.prompt).frame(minHeight: 145).scrollContentBackground(.hidden)
                            .font(.body).focused($editing).accessibilityIdentifier("prompt.editor")
                        Text("\(store.prompt.utf8.count.formatted()) / 32,768 bytes").font(.caption2)
                            .foregroundStyle(store.prompt.utf8.count > 32768 ? .red : .secondary).frame(maxWidth: .infinity, alignment: .trailing)
                        Divider()
                        if !store.chatMode {
                        Button { imagePicker = true; editing = false } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox").font(.title3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.selectedImage).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(imageDescription(store.selectedImage, store.images[store.selectedImage])).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 4); Image(systemName: "chevron.up.chevron.down").font(.caption)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("image.picker")
                        Text("Fresh sandbox for each run · no network or NAS access").font(.caption).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text("Follow-up messages keep a separate conversation for each model.").font(.caption).foregroundStyle(.secondary)
                                Button("New chat") { store.newChat() }.disabled(store.activeCount > 0)
                            }
                        }
                    }
                    Surface {
                        Toggle(isOn: $store.compare) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Compare models").font(.headline)
                                Text(store.chatMode ? "Same message. Separate conversations." : "Same task. Independent sandboxes.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("compare.toggle")
                        Picker(store.compare ? "Model A" : "Model", selection: $store.selectedModel) {
                                ForEach(store.models, id: \.self) { Text(modelTitle($0)).tag($0) }
                            }.accessibilityIdentifier("model.picker")
                        if store.compare {
                            Picker("Model B", selection: $store.comparisonModel) {
                                ForEach(store.models, id: \.self) { Text(modelTitle($0)).tag($0) }
                            }.accessibilityIdentifier("comparison.picker")
                        }
                        if [store.selectedModel, store.compare ? store.comparisonModel : ""].contains("qwen35-4b-steered") {
                            Text("Steered default: L20 N8888 +0.6. Same 4B weights; fixed reference calibration.").font(.caption).foregroundStyle(.secondary)
                        }
                        if !store.chatMode {
                        Divider()
                        Stepper(value: $store.maxSteps, in: 1...300) {
                            HStack { Text("Step budget"); Spacer(); Text("\(store.maxSteps)").monospacedDigit().foregroundStyle(.secondary) }
                        }
                        }
                    }.disabled(store.activeCount > 0)
                    Button {
                        editing = false; store.start()
                    } label: {
                        HStack { Image(systemName: store.compare ? "rectangle.split.2x1" : "play.fill"); Text(store.compare ? "Run comparison" : "Run experiment"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.headline).padding(17).foregroundStyle(.white)
                            .background(store.canRun ? EmbryoStyle.green : Color.gray, in: RoundedRectangle(cornerRadius: 18))
                    }.disabled(!store.canRun).accessibilityIdentifier("run.button")
                    if !store.visibleRunIDs.isEmpty {
                        HStack { Text(store.visibleRunIDs.count > 1 ? "Live comparison" : "Trajectory").font(.title2.bold()); Spacer() }
                        if store.visibleRunIDs.count == 1, let id = store.visibleRunIDs.first {
                            RunLane(id: id, compact: false)
                        } else {
                            GeometryReader { proxy in
                                ScrollView(.horizontal) {
                                    HStack(alignment: .top, spacing: 14) {
                                        ForEach(store.visibleRunIDs, id: \.self) { id in
                                            ScrollView { RunLane(id: id, compact: true) }.frame(width: max(290, min(460, proxy.size.width > 650 ? (proxy.size.width - 14) / 2 : proxy.size.width - 20)))
                                        }
                                    }
                                }.scrollIndicators(.visible)
                            }.frame(height: 640)
                            Text("Swipe across to inspect each model. Token totals include input context.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Observe capability. Save the evidence.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.padding(18).frame(maxWidth: 1080).frame(maxWidth: .infinity)
            }.background(EmbryoStyle.paper)
                .navigationTitle("Embryo").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { store.selectedTab = 2 } label: {
                            HStack(spacing: 5) { Circle().fill(store.connected ? EmbryoStyle.green : .orange).frame(width: 7, height: 7); Text(store.isDemo ? "Sample" : store.connected ? "Connected" : "Connect").font(.caption.weight(.semibold)) }
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } }
                }
                .sheet(isPresented: $imagePicker) { ImagePickerView() }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A SMALL LAB FOR BIG QUESTIONS").font(.caption2.weight(.bold)).tracking(1.8).foregroundStyle(EmbryoStyle.green)
            Text("Compare their answers.").font(.system(size: 30, weight: .bold, design: .serif)).fixedSize(horizontal: false, vertical: true)
            Text("Try the original and steered Qwen with the same message, or test an agent in a sandbox.").font(.subheadline).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(.vertical, 6)
    }
    private var connectionCard: some View {
        Surface {
            Label("Connect to your private lab", systemImage: "network").font(.headline)
            Text("Enable Tailscale, then connect. Embryo uses your Tailscale identity and talks only to dsw-evergreen.").font(.subheadline).foregroundStyle(.secondary)
            Button("Set up connection") { store.selectedTab = 2 }.font(.subheadline.bold())
        }
    }
}

func imageDescription(_ key: String, _ spec: ImageDescriptor?) -> String {
    if key == "science-py312" { return "Python 3.12 · NumPy, SciPy, pandas, scikit-learn" }
    if key == "science-py38-torch" { return "Python 3.8 · SymPy and PyTorch" }
    return spec?.note ?? spec?.repo ?? "Code repair repository · select the task’s matching image"
}

struct ImagePickerView: View {
    @Environment(EmbryoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                if store.imageKeys.isEmpty { Text("Connect to load the sandbox allowlist.").foregroundStyle(.secondary) }
                ForEach(store.imageKeys.filter { search.isEmpty || "\($0) \(imageDescription($0, store.images[$0]))".localizedCaseInsensitiveContains(search) }, id: \.self) { key in
                    Button {
                        store.selectedImage = key; dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(key).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(imageDescription(key, store.images[key])).font(.caption).foregroundStyle(.secondary)
                                Text("Workspace: \(store.images[key]?.cwd ?? "unknown")").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if key == store.selectedImage { Image(systemName: "checkmark.circle.fill") }
                        }.padding(.vertical, 5)
                    }
                }
            }.searchable(text: $search, prompt: "Find a science stack or repository")
                .navigationTitle("Sandbox").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
