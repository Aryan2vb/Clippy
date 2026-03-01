import SwiftUI

enum SidebarTab: String, CaseIterable {
    case organize = "Organize"
    case spaceReclaimer = "Space Reclaimer"
    case aiSuggestions = "AI Suggestions"
    case rules = "Rules"
    case history = "History"
    case search = "Search"
    case statistics = "Statistics"
    
    var title: String {
        switch self {
        case .organize: return UICopy.Sidebar.organize
        case .spaceReclaimer: return "Space Reclaimer"
        case .aiSuggestions: return "AI Suggestions"
        case .rules: return UICopy.Sidebar.rules
        case .history: return UICopy.Sidebar.history
        case .search: return "Search"
        case .statistics: return "Statistics"
        }
    }
    
    var icon: String {
        switch self {
        case .organize: return "folder.badge.gearshape"
        case .spaceReclaimer: return "internaldrive.fill"
        case .aiSuggestions: return "sparkles"
        case .rules: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
        case .search: return "magnifyingglass"
        case .statistics: return "chart.bar"
        }
    }
}
