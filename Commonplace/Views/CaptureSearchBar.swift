import SwiftUI

struct CaptureSearchBar: View {
    @Binding var searchText: String
    let count: Int
    @AppStorage("viewMode") private var viewMode = "grid"

    private var countLabel: String {
        count == 1 ? "1 capture" : "\(count) captures"
    }

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
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Divider().frame(height: 12)
            Button {
                viewMode = viewMode == "grid" ? "timeline" : "grid"
            } label: {
                Image(systemName: viewMode == "grid" ? "list.bullet" : "square.grid.2x2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
