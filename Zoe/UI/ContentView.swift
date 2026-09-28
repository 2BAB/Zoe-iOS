import SwiftUI
import WebKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showsPage = false
    /// In compact width (iPhone, or iPhone Duo folded) the split view collapses into a stack.
    /// Actions that don't change the list selection must still bring the detail column forward.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            sidebar
        } detail: {
            Form {
                statusSection
                if let draft = model.draft {
                    workflowSection(draft, isDraft: true)
                } else if let workflow = model.selectedWorkflow {
                    workflowSection(workflow, isDraft: false)
                    if let result = model.results[workflow.id] { ResultSection(result: result) }
                } else {
                    goalSection
                }
                if !model.log.isEmpty { logSection }
            }
            .formStyle(.grouped)
            .navigationTitle(model.draft?.title ?? model.selectedWorkflow?.title ?? "New Workflow")
            .toolbar {
                Button("Web Page", systemImage: "globe") { showsPage = true }
            }
            .sheet(isPresented: $showsPage) { pageSheet }
        }
        .onChange(of: model.selectedID) { if model.selectedID != nil { compactColumn = .detail } }
        .onChange(of: model.draft) { if model.draft != nil { compactColumn = .detail } }
    }

    private var sidebar: some View {
        List(selection: $model.selectedID) {
            Section {
                Button("New Workflow", systemImage: "plus") {
                    model.draft = nil
                    model.selectedID = nil
                    model.goal = ""
                    compactColumn = .detail
                }
                ForEach(VerifiedPreset.allCases) { preset in
                    Button(preset.title, systemImage: preset.symbol) { model.loadSample(preset) }
                }
            }
            Section("Saved") {
                ForEach(model.workflows) { workflow in
                    Text(workflow.title).lineLimit(2).tag(workflow.id)
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(workflow) }
                        }
                }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle("Zoe")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    private var statusSection: some View {
        Section {
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status)
                Spacer()
                if model.isBusy { Button("Cancel", role: .cancel) { model.cancel() } }
            }
            Label(model.modelStatus, systemImage: "apple.intelligence")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var goalSection: some View {
        Section {
            TextField("Start page", text: $model.startURL)
                .autocorrectionDisabled()
            TextField("What should Zoe find and summarize?", text: $model.goal, axis: .vertical)
                .lineLimit(3...6)
            Picker("Build with", selection: $model.builder) {
                ForEach(BuilderModel.allCases) { Text($0.title).tag($0) }
            }
            if model.builder == .gemini {
                SecureField("Gemini API key", text: $model.geminiKey)
                TextField("Gemini model", text: $model.geminiModel)
                    .autocorrectionDisabled()
            }
            Button("Build Workflow", systemImage: "wand.and.stars") { model.build() }
                .buttonStyle(.borderedProminent)
                .labelStyle(.titleAndIcon)
                .disabled(model.isBusy || model.goal.isEmpty)
        } header: {
            Text("Goal")
        } footer: {
            Text("""
                The builder explores the page and replays the generated workflow on the current site. Saved workflows run on \
                device. Get a Gemini key at aistudio.google.com; it stays in memory. \
                Private Cloud Compute requires Apple's entitlement.
                """)
        }
        .disabled(model.isBusy)
    }

    private func workflowSection(_ workflow: Workflow, isDraft: Bool) -> some View {
        Section {
            Text(workflow.goal)
            Link(workflow.startURL.absoluteString, destination: workflow.startURL)
            Text("Allowed page hosts: \(workflow.hosts.sorted().joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(workflow.steps.enumerated()), id: \.offset) { index, step in
                DisclosureGroup("\(index + 1). \(step.title)") {
                    Text(Self.detail(of: step))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            if isDraft {
                Button("Save Workflow", systemImage: "checkmark.circle.fill") { model.saveDraft() }
                    .buttonStyle(.borderedProminent)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Run on Device", systemImage: "play.fill") { model.runSelected() }
                    .buttonStyle(.borderedProminent)
                    .labelStyle(.titleAndIcon)
            }
        } header: {
            Text(isDraft ? "Review before saving" : "Workflow")
        } footer: {
            if isDraft {
                Text("Saving lets Zoe load these pages, run these scripts, and process the text on device.")
            }
        }
        .disabled(model.isBusy)
    }

    private var logSection: some View {
        Section("Log") {
            ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var pageSheet: some View {
        NavigationStack {
            WebView(model.browser.page)
                .navigationTitle(model.browser.page.url?.host() ?? "Web Page")
                .toolbar {
                    // A semantic placement plus a symbol lets the system place it in the vertical bar on iPhone Duo.
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { showsPage = false }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
        #endif
    }

    private static func detail(of step: Step) -> String {
        step.detail
    }
}

private struct ResultSection: View {
    let result: RunResult

    var body: some View {
        Section {
            Text("Status: \(result.status.rawValue)").font(.headline)
            ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in Text(note).foregroundStyle(.orange) }
            JSONResultView(value: result.output)
            if !result.log.isEmpty {
                DisclosureGroup("Run log") {
                    ForEach(Array(result.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if !result.completedCollections.isEmpty {
                DisclosureGroup("Completed collections — unfinished run") {
                    JSONResultView(value: .object(result.completedCollections))
                }
            }
            ForEach(result.sources, id: \.self) { url in Link(url.absoluteString, destination: url).font(.caption) }
            ShareLink(item: AppModel.text(for: result))
        } header: {
            Text("Last run · \(result.date.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}

/// A generic result renderer: records and evidence stay readable without a news-specific model.
private struct JSONResultView: View {
    let value: JSONValue
    var body: some View {
        switch value {
        case .object(let fields):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key).font(.caption).foregroundStyle(.secondary)
                        JSONResultView(value: fields[key]!)
                    }
                }
            }
        case .array(let records):
            if records.isEmpty { Text("No records in this query scope.").foregroundStyle(.secondary) }
            else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                        if index > 0 { Divider() }
                        JSONResultView(value: record)
                    }
                }
            }
        case .string(let text):
            if let url = URL(string: text), url.scheme == "https", !text.contains(" ") {
                Link(text, destination: url)
            } else { Text(text).textSelection(.enabled) }
        case .null: Text("No value").foregroundStyle(.secondary)
        default: Text(value.text).textSelection(.enabled)
        }
    }
}
