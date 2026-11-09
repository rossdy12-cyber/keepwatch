import SwiftUI

struct MPDiagnosticsView: View {
    @EnvironmentObject private var queueService: MPQueueService

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Status", value: queueService.isConnected ? "Connected" : "Disconnected")

                if let error = queueService.lastError {
                    LabeledContent("Last error", value: error)
                }
            }

            Section("Recent Socket.IO events") {
                if queueService.diagnostics.isEmpty {
                    Text("No events received yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(queueService.diagnostics) { diagnostic in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(diagnostic.event)
                                    .font(.headline)

                                Spacer()

                                Text(diagnostic.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Text(diagnostic.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Queue diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    MPDiagnosticsView()
}
