import SwiftUI

struct LVReaderView: View {
    let link: LVLinkItem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(link.displayTitle).font(.largeTitle.bold())
                Text(link.siteName ?? link.displayHost).foregroundStyle(.secondary)
                Text(link.articleText ?? "No offline snapshot saved.").font(.body).lineSpacing(6).textSelection(.enabled)
            }.frame(maxWidth: 700, alignment: .leading).padding()
        }.navigationTitle("Reader").navigationBarTitleDisplayMode(.inline)
    }
}
