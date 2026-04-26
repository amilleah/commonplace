import SwiftUI

struct CaptureSearchBar: View {
    @Binding var searchText: String
    let count: Int
    @AppStorage("viewMode") private var viewMode = "grid"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Search...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Text(count == 1 ? "1 capture" : "\(count) captures")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Divider().frame(height: 12)
            Button {
                viewMode = viewMode == "grid" ? "timeline" : "grid"
            } label: {
                Image(systemName: viewMode == "grid" ? "list.bullet" : "square.grid.2x2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
