import SwiftUI

struct MainContentView: View {
    @StateObject private var appState = AppState()
    
    var body: some View {
        NavigationSplitView {
            SidebarView(appState: appState)
        } detail: {
            detailView
        }
        .frame(minWidth: 900, minHeight: 600)
    }
    
    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedTab {
        case .organize:
            OrganizeView(appState: appState)
        case .spaceReclaimer:
            SpaceReclaimerView(appState: appState)
        case .aiSuggestions:
            SuggestionsView(appState: appState)
        case .rules:
            RulesView(appState: appState)
        case .history:
            HistoryView(appState: appState)
        case .search:
            GlobalSearchView(appState: appState)
        case .statistics:
            StatisticsDashboardView(appState: appState)
        }
    }
}
