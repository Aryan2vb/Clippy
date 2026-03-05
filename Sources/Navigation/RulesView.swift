import SwiftUI
import ClippyCore
import ClippyEngine

// MARK: - Rules View

struct RulesView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddRule = false
    @State private var editingRule: Rule?
    @State private var isDropTargeted = false
    @State private var prefillData: PrefillData?
    
    var body: some View {
        VStack(spacing: 0) {
            RulesHeaderView(appState: appState, showingAddRule: $showingAddRule)
            Divider()
            if appState.filteredRules.isEmpty {
                if appState.rules.isEmpty {
                    EmptyRulesView(isDropTargeted: $isDropTargeted, onDrop: handleDrop)
                } else {
                    NoMatchingRulesView()
                }
            } else {
                VStack(spacing: 0) {
                    dropHintBanner
                    List {
                        let groupedRules = Dictionary(grouping: appState.filteredRules) { $0.group ?? "Ungrouped" }
                        let sortedGroups = groupedRules.keys.sorted()
                        ForEach(sortedGroups, id: \.self) { group in
                            Section(header: Text(group).font(.headline).foregroundColor(.secondary)) {
                                ForEach(groupedRules[group] ?? []) { rule in
                                    RuleRowView(rule: rule, appState: appState, onEdit: {
                                        editingRule = rule
                                    })
                                }
                                .onDelete { indexSet in
                                    let rulesInGroup = groupedRules[group] ?? []
                                    let rulesToDelete = indexSet.map { rulesInGroup[$0] }
                                    appState.rules.removeAll { rule in
                                        rulesToDelete.contains { $0.id == rule.id }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers: providers)
                        return true
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .sheet(isPresented: $showingAddRule) {
            RuleEditorView(appState: appState, existingRule: nil, prefillData: prefillData)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(appState: appState, existingRule: rule)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        var prefill = PrefillData()
                        prefill.fileExtension = url.pathExtension.lowercased()
                        prefill.fileName = url.lastPathComponent
                        
                        let home = NSHomeDirectory()
                        let documentsPath = home + "/Documents/"
                        let extFolder = prefill.fileExtension.isEmpty ? "Others" : prefill.fileExtension.uppercased()
                        prefill.suggestedDestination = documentsPath + extFolder
                        
                        self.prefillData = prefill
                        self.showingAddRule = true
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var dropHintBanner: some View {
        HStack {
            Image(systemName: "arrow.down.doc")
                .foregroundColor(isDropTargeted ? .white : .accentColor)
            Text(isDropTargeted ? "Drop to create rule!" : "Drop a file here to create a rule")
                .font(.caption)
                .foregroundColor(isDropTargeted ? .white : .secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isDropTargeted ? Color.accentColor : Color.accentColor.opacity(0.1))
        .cornerRadius(8)
        .padding(12)
        .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
    }
}

// MARK: - Rules Header

struct RulesHeaderView: View {
    @ObservedObject var appState: AppState
    @Binding var showingAddRule: Bool
    @State private var showingTemplates = false
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(UICopy.Rules.title).font(.title2).fontWeight(.semibold)
                    Text(UICopy.Rules.subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        let enabledCount = appState.rules.filter(\.isEnabled).count
                        if enabledCount == appState.rules.count {
                            appState.disableAllRules()
                        } else {
                            appState.enableAllRules()
                        }
                    } label: {
                        let enabledCount = appState.rules.filter(\.isEnabled).count
                        Label(
                            enabledCount == appState.rules.count ? "Disable All" : "Enable All",
                            systemImage: enabledCount == appState.rules.count ? "checkmark.circle.slash" : "checkmark.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    
                    Button { showingTemplates = true } label: {
                        Label("Templates", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    Button { showingAddRule = true } label: {
                        Label(UICopy.Rules.addButton, systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .sheet(isPresented: $showingTemplates) {
                TemplateBrowserView(appState: appState)
            }
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search rules...", text: $appState.ruleSearchText).textFieldStyle(.plain)
                    if !appState.ruleSearchText.isEmpty {
                        Button { appState.ruleSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                if !appState.ruleGroups.isEmpty {
                    Picker("Group", selection: $appState.selectedRuleGroup) {
                        Text("All Groups").tag(nil as String?)
                        ForEach(appState.ruleGroups, id: \.self) { group in
                            Text(group).tag(group as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                Spacer()
                Text("\(appState.filteredRules.count) of \(appState.rules.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Empty States

struct NoMatchingRulesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass").font(.system(size: 48)).foregroundColor(.secondary.opacity(0.5))
            Text("No matching rules").font(.title3).fontWeight(.medium)
            Text("Try adjusting your search or filter criteria.").font(.body).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyRulesView: View {
    @Binding var isDropTargeted: Bool
    var onDrop: ([NSItemProvider]) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 48)).foregroundColor(.secondary.opacity(0.5))
            Text(UICopy.Rules.emptyTitle).font(.title3).fontWeight(.medium)
            Text(UICopy.Rules.emptyBody).font(.body).foregroundColor(.secondary).multilineTextAlignment(.center)
            
            Divider()
                .frame(width: 200)
                .padding(.vertical, 20)
            
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 32))
                    .foregroundColor(isDropTargeted ? .accentColor : .secondary.opacity(0.5))
                
                Text("Drop files here to create rules")
                    .font(.subheadline)
                    .foregroundColor(isDropTargeted ? .accentColor : .secondary)
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
            )
            .scaleEffect(isDropTargeted ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            onDrop(providers)
            return true
        }
    }
}

// MARK: - Rule Row

struct RuleRowView: View {
    let rule: Rule
    @ObservedObject var appState: AppState
    let onEdit: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { newValue in
                    if let index = appState.rules.firstIndex(where: { $0.id == rule.id }) {
                        appState.rules[index] = Rule(
                            id: rule.id, name: rule.name, description: rule.description,
                            conditions: rule.conditions, outcome: rule.outcome,
                            isEnabled: newValue, group: rule.group, tags: rule.tags
                        )
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rule.name).fontWeight(.medium)
                    if !rule.isEnabled {
                        Text(UICopy.Rules.disabled).font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2)).cornerRadius(4)
                    }
                    if !rule.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(rule.tags.prefix(3), id: \.self) { tag in
                                Text(tag).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.1)).foregroundColor(.accentColor).cornerRadius(4)
                            }
                            if rule.tags.count > 3 {
                                Text("+\(rule.tags.count - 3)").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // Conditions summary
                Text(conditionsSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    ForEach(Array(rule.conditions.enumerated()), id: \.offset) { _, condition in
                        ConditionBadge(condition: condition)
                    }
                    Text("→").foregroundColor(.secondary)
                    OutcomeChipView(outcome: rule.outcome)
                }
                .font(.caption2)
            }
            Spacer()
            Button(UICopy.Rules.editButton) { onEdit() }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 8)
        .opacity(rule.isEnabled ? 1 : 0.6)
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                appState.rules.removeAll { $0.id == rule.id }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private var conditionsSummary: String {
        let parts: [String] = rule.conditions.map { condition in
            switch condition {
            case .fileExtension(let ext): return "ext: \(ext)"
            case .fileName(let contains): return "name: \(contains)"
            case .fileNameExact(let exact): return "name: \(exact)"
            case .fileNamePrefix(let prefix): return "starts: \(prefix)"
            case .fileSize(let bytes):
                return "size > \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            case .createdBefore(let date):
                return "created < \(date.formatted(date: .abbreviated, time: .omitted))"
            case .modifiedBefore(let date):
                return "modified < \(date.formatted(date: .abbreviated, time: .omitted))"
            case .isDirectory:
                return "is folder"
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Condition Badge

struct ConditionBadge: View {
    let condition: RuleCondition
    var body: some View {
        Text(conditionText)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(4)
    }
    private var conditionText: String {
        switch condition {
        case .fileExtension(let ext): return UICopy.Common.conditionExt(ext)
        case .fileName(let contains): return UICopy.Common.conditionContains(contains)
        case .fileNameExact(let exact): return UICopy.Common.conditionContains(exact)
        case .fileNamePrefix(let prefix): return UICopy.Common.conditionContains(prefix)
        case .fileSize(let bytes): return UICopy.Common.conditionSize(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        case .createdBefore(let date): return "created " + UICopy.Common.conditionDate(date.formatted(date: .abbreviated, time: .omitted))
        case .modifiedBefore(let date): return "modified " + UICopy.Common.conditionDate(date.formatted(date: .abbreviated, time: .omitted))
        case .isDirectory: return UICopy.Common.conditionFolder
        }
    }
}


// MARK: - Prefill Data

struct PrefillData {
    var fileExtension: String = ""
    var fileName: String = ""
    var suggestedDestination: String = ""
}

// MARK: - Rule Editor

struct RuleEditorView: View {
    @ObservedObject var appState: AppState
    let existingRule: Rule?
    var prefillData: PrefillData?
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var conditions: [ConditionEntry] = [ConditionEntry()]
    @State private var outcomeType: OutcomeType = .move
    @State private var destinationPath: String = ""
    @State private var renamePrefix: String = ""
    @State private var renameSuffix: String = ""
    @State private var skipReason: String = ""
    @State private var showSecurityError = false
    @State private var group: String = ""
    @State private var tags: String = ""
    @State private var validationError: String?
    
    // MARK: - Condition Types
    
    enum ConditionType: String, CaseIterable, Identifiable {
        case fileExtension = "File Extension"
        case fileName = "File Name Contains"
        case fileSize = "File Size Larger Than"
        case createdBefore = "Created Before"
        case modifiedBefore = "Modified Before"
        case isDirectory = "Is Directory"
        
        var id: String { rawValue }
    }
    
    struct ConditionEntry: Identifiable {
        let id = UUID()
        var type: ConditionType = .fileExtension
        var value: String = ""
        var dateValue: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    }
    
    // MARK: - Outcome Types
    
    enum OutcomeType: String, CaseIterable, Identifiable {
        case move = "Move to Folder"
        case copy = "Copy to Folder"
        case delete = "Move to Trash"
        case rename = "Rename"
        case skip = "Skip (do nothing)"
        
        var id: String { rawValue }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(existingRule == nil ? UICopy.Rules.editorAddTitle : UICopy.Rules.editorEditTitle).font(.headline)
                Spacer()
                Button(UICopy.Rules.cancelButton) { dismiss() }.keyboardShortcut(.escape)
            }
            .padding()
            Divider()
            
            ScrollView {
                VStack(spacing: 24) {
                    // Details section
                    GroupBox(label: Text(UICopy.Rules.sectionDetails).font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Name", text: $name, prompt: Text(UICopy.Rules.namePlaceholder))
                            TextField("Description", text: $description, prompt: Text(UICopy.Rules.descPlaceholder))
                            HStack {
                                Text("Group:").foregroundColor(.secondary)
                                TextField("Group name", text: $group, prompt: Text("Optional"))
                                if !appState.ruleGroups.isEmpty {
                                    Picker("", selection: $group) {
                                        Text("Select...").tag("")
                                        ForEach(appState.ruleGroups, id: \.self) { g in Text(g).tag(g) }
                                    }
                                    .pickerStyle(.menu).frame(width: 120)
                                }
                            }
                            HStack {
                                Text("Tags:").foregroundColor(.secondary)
                                TextField("Comma separated tags", text: $tags, prompt: Text("e.g., important, archive, work"))
                            }
                        }
                        .padding(8)
                    }
                    
                    // Conditions section (add/remove multiple)
                    GroupBox(label: HStack {
                        Text(UICopy.Rules.sectionConditions).font(.headline)
                        Spacer()
                        Button {
                            conditions.append(ConditionEntry())
                        } label: {
                            Label("Add Condition", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }) {
                        VStack(spacing: 12) {
                            ForEach(Array(conditions.enumerated()), id: \.element.id) { index, entry in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Picker("Condition", selection: $conditions[index].type) {
                                            ForEach(ConditionType.allCases) { type in
                                                Text(type.rawValue).tag(type)
                                            }
                                        }
                                        .labelsHidden()
                                        
                                        conditionValueField(for: index)
                                    }
                                    
                                    if conditions.count > 1 {
                                        Button {
                                            conditions.remove(at: index)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                
                                if index < conditions.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .padding(8)
                    }
                    
                    // Outcome section
                    GroupBox(label: Text(UICopy.Rules.sectionOutcomes).font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Action", selection: $outcomeType) {
                                ForEach(OutcomeType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .labelsHidden()
                            
                            switch outcomeType {
                            case .move, .copy:
                                HStack {
                                    TextField("Destination folder path", text: $destinationPath, prompt: Text("~/Documents/Archive"))
                                    Button("Browse…") {
                                        browseForFolder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            case .rename:
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Prefix:").font(.caption).foregroundColor(.secondary)
                                        TextField("Prefix", text: $renamePrefix, prompt: Text("archived_"))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Suffix:").font(.caption).foregroundColor(.secondary)
                                        TextField("Suffix", text: $renameSuffix, prompt: Text("_old"))
                                    }
                                }
                            case .skip:
                                TextField("Reason for skipping", text: $skipReason, prompt: Text("e.g., System file, do not modify"))
                            case .delete:
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Text("Files matching this rule will be moved to Trash.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(8)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                if let error = validationError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button(UICopy.Rules.cancelButton) { dismiss() }
                    .buttonStyle(.bordered)
                Button(UICopy.Rules.saveButton) { saveRule() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 550)
        .alert("Security Error", isPresented: $showSecurityError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The selected destination path is not allowed. Please choose a path within your home directory or Documents folder.")
        }
        .onAppear {
            populateFields()
        }
    }
    
    // MARK: - Condition Value Field
    
    @ViewBuilder
    private func conditionValueField(for index: Int) -> some View {
        switch conditions[index].type {
        case .fileExtension:
            TextField("Extension", text: $conditions[index].value, prompt: Text("pdf"))
        case .fileName:
            TextField("Contains", text: $conditions[index].value, prompt: Text("Screenshot"))
        case .fileSize:
            TextField("Size in MB", text: $conditions[index].value, prompt: Text("100"))
        case .createdBefore:
            DatePicker("Before:", selection: $conditions[index].dateValue, displayedComponents: .date)
        case .modifiedBefore:
            DatePicker("Before:", selection: $conditions[index].dateValue, displayedComponents: .date)
        case .isDirectory:
            Text("Matches all directories/folders")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Populate from existing rule or prefill
    
    private func populateFields() {
        if let rule = existingRule {
            name = rule.name
            description = rule.description
            group = rule.group ?? ""
            tags = rule.tags.joined(separator: ", ")
            
            // Populate conditions
            conditions = rule.conditions.map { condition in
                var entry = ConditionEntry()
                switch condition {
                case .fileExtension(let ext):
                    entry.type = .fileExtension
                    entry.value = ext
                case .fileName(let contains):
                    entry.type = .fileName
                    entry.value = contains
                case .fileNameExact(let exact):
                    entry.type = .fileName
                    entry.value = exact
                case .fileNamePrefix(let prefix):
                    entry.type = .fileName
                    entry.value = prefix
                case .fileSize(let bytes):
                    entry.type = .fileSize
                    entry.value = "\(bytes / 1_000_000)"
                case .createdBefore(let date):
                    entry.type = .createdBefore
                    entry.dateValue = date
                case .modifiedBefore(let date):
                    entry.type = .modifiedBefore
                    entry.dateValue = date
                case .isDirectory:
                    entry.type = .isDirectory
                }
                return entry
            }
            if conditions.isEmpty {
                conditions = [ConditionEntry()]
            }
            
            // Populate outcome
            switch rule.outcome {
            case .move(let url):
                outcomeType = .move
                destinationPath = url.path
            case .copy(let url):
                outcomeType = .copy
                destinationPath = url.path
            case .delete:
                outcomeType = .delete
            case .rename(let prefix, let suffix):
                outcomeType = .rename
                renamePrefix = prefix ?? ""
                renameSuffix = suffix ?? ""
            case .skip(let reason):
                outcomeType = .skip
                skipReason = reason
            }
        } else if let prefill = prefillData {
            if !prefill.fileExtension.isEmpty {
                conditions = [ConditionEntry()]
                conditions[0].type = .fileExtension
                conditions[0].value = prefill.fileExtension
            }
            if !prefill.suggestedDestination.isEmpty {
                destinationPath = prefill.suggestedDestination
            }
        }
    }
    
    // MARK: - Save Rule
    
    private func saveRule() {
        // Build conditions
        let ruleConditions: [RuleCondition] = conditions.compactMap { entry in
            switch entry.type {
            case .fileExtension:
                guard !entry.value.isEmpty else { return nil }
                return .fileExtension(is: entry.value)
            case .fileName:
                guard !entry.value.isEmpty else { return nil }
                return .fileName(contains: entry.value)
            case .fileSize:
                let mb = Int64(entry.value) ?? 100
                return .fileSize(largerThan: mb * 1_000_000)
            case .createdBefore:
                return .createdBefore(date: entry.dateValue)
            case .modifiedBefore:
                return .modifiedBefore(date: entry.dateValue)
            case .isDirectory:
                return .isDirectory
            }
        }
        
        guard !ruleConditions.isEmpty else { return }
        
        // Build outcome
        let outcome: RuleOutcome
        switch outcomeType {
        case .move:
            let path = resolvePath(destinationPath)
            guard isPathAllowed(path) else { showSecurityError = true; return }
            outcome = .move(to: URL(fileURLWithPath: path))
        case .copy:
            let path = resolvePath(destinationPath)
            guard isPathAllowed(path) else { showSecurityError = true; return }
            outcome = .copy(to: URL(fileURLWithPath: path))
        case .delete:
            outcome = .delete
        case .rename:
            outcome = .rename(
                prefix: renamePrefix.isEmpty ? nil : renamePrefix,
                suffix: renameSuffix.isEmpty ? nil : renameSuffix
            )
        case .skip:
            outcome = .skip(reason: skipReason.isEmpty ? "Manually skipped" : skipReason)
        }
        
        let rule = Rule(
            id: existingRule?.id ?? UUID(), name: name, description: description,
            conditions: ruleConditions, outcome: outcome,
            group: group.isEmpty ? nil : group,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        
        // Validate rule before saving
        let validationResult = RuleValidator.validate(rule)
        guard validationResult.isValid else {
            validationError = validationResult.errors.joined(separator: ". ")
            return
        }
        validationError = nil
        
        if let existing = existingRule, let index = appState.rules.firstIndex(where: { $0.id == existing.id }) {
            appState.rules[index] = rule
        } else {
            appState.rules.append(rule)
        }
        dismiss()
    }
    
    private func resolvePath(_ path: String) -> String {
        if path.isEmpty {
            return NSHomeDirectory() + "/Documents/Organized"
        }
        if path.hasPrefix("~") {
            return NSHomeDirectory() + String(path.dropFirst())
        }
        return path
    }
    
    private func isPathAllowed(_ path: String) -> Bool {
        let allowedPrefixes = [NSHomeDirectory(), "/tmp/", FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""]
        let resolvedPath = (path as NSString).standardizingPath
        let blockedPrefixes = ["/System", "/usr/bin", "/usr/sbin", "/bin", "/sbin", "/etc", "/var", "/private", "/dev", "/Applications", NSHomeDirectory() + "/Library"]
        for blocked in blockedPrefixes { if resolvedPath.hasPrefix(blocked) { return false } }
        return allowedPrefixes.contains { resolvedPath.hasPrefix($0) }
    }
    
    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose a destination folder for this rule"
        
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }
}
