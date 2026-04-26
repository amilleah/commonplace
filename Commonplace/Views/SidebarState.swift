import SwiftUI
import Combine

final class SidebarState: ObservableObject {
    @Published var selectedFilter: CaptureFilter = .all
    @Published var selectedApp: String? = nil
    @Published var selectedTagIds: Set<String> = []
    @Published var showSettings = false
}
