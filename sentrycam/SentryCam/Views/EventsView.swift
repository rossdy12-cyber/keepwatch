import SwiftUI

struct EventsView: View {
    @EnvironmentObject private var settings: FrigateSettings
    @EnvironmentObject private var store: FrigateStore
    @State private var clip: FrigateEvent?

    var body: some View {
        NavigationStack {
            Group {
                if !settings.isConfigured {
                    ConfigurePrompt()
                } else {
                    List {
                        if store.events.isEmpty {
                            Text("No recent events.").foregroundStyle(Theme.secondaryText).font(.footnote)
                        }
                        ForEach(store.events) { event in
                            Button { clip = event } label: { EventRow(client: settings.client, event: event) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Events")
            .refreshable { await store.reloadEvents(settings) }
            .sheet(item: $clip) { event in ClipPlayer(client: settings.client, event: event) }
        }
    }
}

private struct EventRow: View {
    let client: FrigateClient
    let event: FrigateEvent

    var body: some View {
        HStack(spacing: 12) {
            AuthImage(client: client, path: client.thumbPath(event.id)) {
                ZStack { Color.gray.opacity(0.2); Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .scaledToFill()
            .frame(width: 78, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.label.capitalized).font(.subheadline.bold())
                    if event.score > 0 {
                        Text("\(Int(event.score * 100))%")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.22), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text("\(event.camera.prettyCamera) · \(Date(timeIntervalSince1970: event.startTime).formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Image(systemName: event.hasClip ? "play.circle.fill" : "photo.circle")
                .font(.title2).foregroundStyle(event.hasClip ? Theme.accent : Theme.secondaryText)
        }
        .padding(.vertical, 2)
    }
}
