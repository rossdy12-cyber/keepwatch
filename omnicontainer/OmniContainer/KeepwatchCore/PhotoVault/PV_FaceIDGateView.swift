import SwiftUI

struct PVFaceIDGateView: View {
    @EnvironmentObject private var auth: PVAuthViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "faceid")
                .font(.system(size: 72))
                .foregroundStyle(.blue)

            Text("PhotoVault is locked")
                .font(.title2.bold())

            Text("Use Face ID to open your private PhotoPrism library.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                Task { await auth.requestUnlock() }
            } label: {
                Text("Unlock")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue, in: .rect(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal)
        }
        .padding()
        .task {
            await auth.requestUnlock()
        }
    }
}
