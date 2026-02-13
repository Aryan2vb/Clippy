import Foundation

// MARK: - Search Types

/// Types of searchable items in the application
public enum SearchableItemType: String, CaseIterable, Sendable {
    case file = "Files"
    case rule = "Rules"
    case history = "History"
}

/// Represents a searchable item with unified interface
public struct SearchResultItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let type: SearchableItemType
    public let title: String
    public let subtitle: String
    public let icon: String
    public let associatedData: AnySendable
    
    public init<T: Sendable>(id: UUID = UUID(), type: SearchableItemType, title: String, subtitle: String, icon: String, data: T) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.associatedData = AnySendable(data)
    }
    
    public static func == (lhs: SearchResultItem, rhs: SearchResultItem) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Type-erased wrapper for Sendable values
public struct AnySendable: @unchecked Sendable, Equatable {
    private let _value: Any
    private let _id: UUID
    
    public init<T: Sendable>(_ value: T) {
        self._value = value
        self._id = UUID()
    }
    
    public func asType<T: Sendable>(_ type: T.Type) -> T? {
        return _value as? T
    }
    
    public static func == (lhs: AnySendable, rhs: AnySendable) -> Bool {
        lhs._id == rhs._id
    }
}

// MARK: - Search Manager

/// Centralized search functionality for files, rules, and history
@MainActor
public final class SearchManager: ObservableObject {
    @Published public private(set) var searchResults: [SearchResultItem] = []
    @Published public private(set) var isSearching = false
    @Published public var selectedTypes: Set<SearchableItemType> = Set(SearchableItemType.allCases)
    
    private var files: [FileDescriptor] = []
    private var rules: [Rule] = []
    private var historySessions: [HistorySession] = []
    
    public init() {}
    
    /// Updates the searchable data
    public func updateData(files: [FileDescriptor] = [], rules: [Rule] = [], history: [HistorySession] = []) {
        self.files = files
        self.rules = rules
        self.historySessions = history
    }
    
    /// Performs search across all enabled types
    public func search(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        let lowerQuery = query.lowercased()
        var results: [SearchResultItem] = []
        
        // Search files
        if selectedTypes.contains(.file) {
            results.append(contentsOf: searchFiles(query: lowerQuery))
        }
        
        // Search rules
        if selectedTypes.contains(.rule) {
            results.append(contentsOf: searchRules(query: lowerQuery))
        }
        
        // Search history
        if selectedTypes.contains(.history) {
            results.append(contentsOf: searchHistory(query: lowerQuery))
        }
        
        searchResults = results
        isSearching = false
    }
    
    private func searchFiles(query: String) -> [SearchResultItem] {
        return files.compactMap { file in
            let nameMatch = file.fileName.lowercased().contains(query)
            let extMatch = file.fileExtension.lowercased().contains(query)
            let pathMatch = file.fileURL.path.lowercased().contains(query)
            
            guard nameMatch || extMatch || pathMatch else { return nil }
            
            let icon = file.isDirectory ? "folder" : "doc"
            let subtitle = file.isDirectory 
                ? file.fileURL.deletingLastPathComponent().path
                : "\(ByteCountFormatter.string(fromByteCount: file.fileSize ?? 0, countStyle: .file)) • \(file.fileExtension)"
            
            return SearchResultItem(
                type: .file,
                title: file.fileName,
                subtitle: subtitle,
                icon: icon,
                data: file
            )
        }
    }
    
    private func searchRules(query: String) -> [SearchResultItem] {
        return rules.compactMap { rule in
            let nameMatch = rule.name.lowercased().contains(query)
            let descMatch = rule.description.lowercased().contains(query)
            let tagMatch = rule.tags.contains { $0.lowercased().contains(query) }
            let groupMatch = rule.group?.lowercased().contains(query) ?? false
            
            guard nameMatch || descMatch || tagMatch || groupMatch else { return nil }
            
            let subtitle = rule.group != nil 
                ? "\(rule.group!) • \(rule.conditions.count) conditions"
                : "\(rule.conditions.count) conditions"
            
            return SearchResultItem(
                type: .rule,
                title: rule.name,
                subtitle: subtitle,
                icon: "list.bullet.rectangle",
                data: rule
            )
        }
    }
    
    private func searchHistory(query: String) -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        
        for session in historySessions {
            for item in session.items {
                let nameMatch = item.fileName.lowercased().contains(query)
                let pathMatch = item.originalPath.lowercased().contains(query) ||
                               (item.currentPath?.lowercased().contains(query) ?? false)
                let actionMatch = item.actionType.rawValue.lowercased().contains(query)
                
                guard nameMatch || pathMatch || actionMatch else { continue }
                
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                let timeAgo = formatter.localizedString(for: item.timestamp, relativeTo: Date())
                
                results.append(SearchResultItem(
                    type: .history,
                    title: item.fileName,
                    subtitle: "\(item.actionType.rawValue) • \(timeAgo)",
                    icon: item.actionType.icon,
                    data: item
                ))
            }
        }
        
        return results
    }
    
    /// Clears all search results
    public func clearSearch() {
        searchResults = []
    }
}

// MARK: - File Filtering Helper

extension FileDescriptor {
    /// Checks if file matches search criteria
    func matches(searchQuery: String) -> Bool {
        let query = searchQuery.lowercased()
        return fileName.lowercased().contains(query)
            || fileExtension.lowercased().contains(query)
            || fileURL.path.lowercased().contains(query)
    }
}
