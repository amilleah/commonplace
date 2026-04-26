import SwiftUI

/// Top-level view for the Browse window. Owns the sidebar state and data so
/// `CaptureFilterSidebar` persists across view switches without flickering.
struct RootContentView: View {
    @StateObject private var sidebarState = SidebarState()
    @AppStorage("viewMode") private var viewMode = "grid"

    @State private var appFacets: [AppFacet] = []
    @State private var allTags: [Tag] = []
    @State private var tagCounts: [String: Int] = [:]
    @State private var typeCounts: [String: Int] = [:]

    var body: some View {
        HStack(spacing: 0) {
            CaptureFilterSidebar(
                appFacets: appFacets,
                allTags: allTags,
                tagCounts: tagCounts,
                typeCounts: typeCounts,
                selectedApp: $sidebarState.selectedApp,
                selectedFilter: $sidebarState.selectedFilter,
                selectedTagIds: $sidebarState.selectedTagIds,
                showSettings: $sidebarState.showSettings
            )

            Divider()

            if viewMode == "timeline" {
                TimelineView(
                    sidebarState: sidebarState,
                    appFacets: $appFacets,
                    allTags: $allTags,
                    tagCounts: $tagCounts,
                    typeCounts: $typeCounts
                )
            } else {
                BrowseView(
                    sidebarState: sidebarState,
                    appFacets: $appFacets,
                    allTags: $allTags,
                    tagCounts: $tagCounts,
                    typeCounts: $typeCounts
                )
            }
        }
    }
}
