import SwiftUI

// The iPhone side of Stark Face. It exists so the Stark Store can deliver the watch app:
// iOS installs the Watch app inside this one onto the paired Apple Watch.

@main
struct StarkFacePhoneApp: App {
    var body: some Scene {
        WindowGroup { HomeView().preferredColorScheme(.dark) }
    }
}

private let crimson = Color(red: 0.75, green: 0.06, blue: 0.19)
private let rose = Color(red: 0.91, green: 0.25, blue: 0.36)

struct HomeView: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.02, blue: 0.02).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "applewatch.watchface").font(.system(size: 44)).foregroundStyle(rose)
                        Text("Stark Face").font(.largeTitle.bold())
                        Text("Lives on your Apple Watch.").foregroundStyle(.secondary)
                    }

                    step(1, "Open the Watch app", "On this iPhone, open Watch and go to the My Watch tab.")
                    step(2, "Install Stark Face", "Scroll to Available Apps and tap Install next to Stark Face. If it's already under Installed on Apple Watch, it's done.")
                    step(3, "Add the complications", "Edit a face such as Modular or Infograph and pick NAS status, Last detection, Ask Jarvis, Nocturne or Stark Face.")
                    step(4, "Keep it up front", "On the watch: Settings → General → Return to Clock → Stark Face → After 1 hour.")

                    Button {
                        if let u = URL(string: "itms-watchs://") { UIApplication.shared.open(u) }
                    } label: {
                        Label("Open the Watch app", systemImage: "applewatch")
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(crimson))
                            .foregroundStyle(.white).font(.headline)
                    }

                    Text("Live data comes from your NAS over Tailscale, so keep Tailscale connected on this iPhone. Nocturne and payday are set up on the watch's Settings page.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.headline).frame(width: 30, height: 30)
                .background(Circle().fill(crimson.opacity(0.25))).foregroundStyle(rose)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
