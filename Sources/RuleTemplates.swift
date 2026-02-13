import Foundation

// MARK: - Rule Templates

/// Pre-defined rule templates for common organization patterns
public struct RuleTemplate: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let category: TemplateCategory
    public let icon: String
    public let rule: Rule
    
    public init(id: UUID = UUID(), name: String, description: String, category: TemplateCategory, icon: String, rule: Rule) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.icon = icon
        self.rule = rule
    }
}

public enum TemplateCategory: String, CaseIterable, Sendable {
    case documents = "Documents"
    case images = "Images"
    case development = "Development"
    case media = "Media"
    case archives = "Archives"
    case productivity = "Productivity"
    
    public var icon: String {
        switch self {
        case .documents: return "doc.text"
        case .images: return "photo"
        case .development: return "chevron.left.forwardslash.chevron.right"
        case .media: return "play.circle"
        case .archives: return "archivebox"
        case .productivity: return "checkmark.circle"
        }
    }
}

// MARK: - Template Library

public struct RuleTemplateLibrary {
    /// All available templates
    public static let allTemplates: [RuleTemplate] = [
        // Documents
        RuleTemplate(
            name: "Archive Old Documents",
            description: "Move documents older than 30 days to archive",
            category: .documents,
            icon: "doc.text",
            rule: Rule(
                name: "Archive Old Documents",
                description: "Move documents older than 30 days to archive",
                conditions: [
                    .fileExtension(is: "pdf"),
                    .modifiedBefore(date: Date().addingTimeInterval(-30 * 24 * 60 * 60))
                ],
                outcome: .move(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Archive")),
                group: "Documents",
                tags: ["archive", "old", "cleanup"]
            )
        ),
        
        RuleTemplate(
            name: "Organize Spreadsheets",
            description: "Move Excel and CSV files to Spreadsheets folder",
            category: .documents,
            icon: "tablecells",
            rule: Rule(
                name: "Organize Spreadsheets",
                description: "Move Excel and CSV files to Spreadsheets folder",
                conditions: [.fileExtension(is: "xlsx")],
                outcome: .move(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Spreadsheets")),
                group: "Documents",
                tags: ["excel", "csv", "data"]
            )
        ),
        
        // Images
        RuleTemplate(
            name: "Organize Screenshots",
            description: "Move screenshots to dedicated folder",
            category: .images,
            icon: "camera",
            rule: Rule(
                name: "Organize Screenshots",
                description: "Move screenshots to dedicated folder",
                conditions: [.fileName(contains: "Screenshot")],
                outcome: .move(to: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!.appendingPathComponent("Screenshots")),
                group: "Images",
                tags: ["screenshot", "cleanup"]
            )
        ),
        
        RuleTemplate(
            name: "Organize Photos by Type",
            description: "Sort photos by format (JPG, PNG, HEIC)",
            category: .images,
            icon: "photo.stack",
            rule: Rule(
                name: "Organize JPG Photos",
                description: "Move JPG images to Photos folder",
                conditions: [.fileExtension(is: "jpg")],
                outcome: .move(to: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!.appendingPathComponent("Photos/JPG")),
                group: "Images",
                tags: ["photos", "jpg", "organize"]
            )
        ),
        
        // Development
        RuleTemplate(
            name: "Organize Code Files",
            description: "Sort code files by language",
            category: .development,
            icon: "curlybraces",
            rule: Rule(
                name: "Organize Swift Files",
                description: "Move Swift files to Code folder",
                conditions: [.fileExtension(is: "swift")],
                outcome: .move(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Code/Swift")),
                group: "Development",
                tags: ["code", "swift", "development"]
            )
        ),
        
        RuleTemplate(
            name: "Organize Git Repositories",
            description: "Move downloaded repos to Projects folder",
            category: .development,
            icon: "folder.badge.gear",
            rule: Rule(
                name: "Organize Git Repositories",
                description: "Move downloaded repos to Projects folder",
                conditions: [.fileExtension(is: "git")],
                outcome: .move(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Projects")),
                group: "Development",
                tags: ["git", "repo", "development"]
            )
        ),
        
        // Media
        RuleTemplate(
            name: "Organize Videos",
            description: "Move video files to Movies folder",
            category: .media,
            icon: "video",
            rule: Rule(
                name: "Organize Videos",
                description: "Move video files to Movies folder",
                conditions: [.fileExtension(is: "mp4")],
                outcome: .move(to: FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!),
                group: "Media",
                tags: ["video", "mp4", "movies"]
            )
        ),
        
        RuleTemplate(
            name: "Organize Audio Files",
            description: "Sort audio files by format",
            category: .media,
            icon: "music.note",
            rule: Rule(
                name: "Organize MP3 Music",
                description: "Move MP3 audio files to Music folder",
                conditions: [.fileExtension(is: "mp3")],
                outcome: .move(to: FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!.appendingPathComponent("MP3")),
                group: "Media",
                tags: ["music", "mp3", "audio"]
            )
        ),
        
        // Archives
        RuleTemplate(
            name: "Organize Downloads",
            description: "Move archives to Archives folder",
            category: .archives,
            icon: "archivebox",
            rule: Rule(
                name: "Organize ZIP Archives",
                description: "Move ZIP files to Archives folder",
                conditions: [.fileExtension(is: "zip")],
                outcome: .move(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Archives")),
                group: "Archives",
                tags: ["zip", "archive", "downloads"]
            )
        ),
        
        RuleTemplate(
            name: "Clean Old Downloads",
            description: "Move files older than 7 days from Downloads",
            category: .archives,
            icon: "trash",
            rule: Rule(
                name: "Clean Old Downloads",
                description: "Move files older than 7 days from Downloads",
                conditions: [
                    .fileSize(largerThan: 0),
                    .modifiedBefore(date: Date().addingTimeInterval(-7 * 24 * 60 * 60))
                ],
                outcome: .move(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Old Downloads")),
                group: "Archives",
                tags: ["cleanup", "old", "downloads"]
            )
        ),
        
        // Productivity
        RuleTemplate(
            name: "Organize Large Files",
            description: "Review files larger than 100MB",
            category: .productivity,
            icon: "externaldrive",
            rule: Rule(
                name: "Clean Large Files",
                description: "Move files larger than 100MB to a review folder",
                conditions: [.fileSize(largerThan: 100_000_000)],
                outcome: .move(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Large Files")),
                group: "Productivity",
                tags: ["large", "review", "storage"]
            )
        ),
        
        RuleTemplate(
            name: "Daily Cleanup",
            description: "Organize files created today",
            category: .productivity,
            icon: "calendar.badge.clock",
            rule: Rule(
                name: "Daily Cleanup",
                description: "Organize files created today",
                conditions: [
                    .createdBefore(date: Date()),
                    .fileExtension(is: "tmp")
                ],
                outcome: .delete,
                group: "Productivity",
                tags: ["daily", "cleanup", "temp"]
            )
        )
    ]
    
    /// Get templates by category
    public static func templates(for category: TemplateCategory) -> [RuleTemplate] {
        allTemplates.filter { $0.category == category }
    }
    
    /// Get featured/popular templates
    public static var featuredTemplates: [RuleTemplate] {
        Array(allTemplates.prefix(6))
    }
}
