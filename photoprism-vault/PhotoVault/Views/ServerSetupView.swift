import SwiftUI

struct ServerSetupView: View {
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("PhotoPrism server") {
                    TextField("https://photos.example.com", text: $auth.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("PhotoPrism username", text: $auth.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("PhotoPrism app password", text: $auth.appPassword)
                }

                Section {
                    Button {
                        Task { await auth.signIn() }
                    } label: {
                        if auth.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Sign in")
                                .frame(maxWidth: .infinity)
                                .bold()
                        }
                    }
                    .disabled(auth.isLoading || auth.serverURL.isEmpty || auth.username.isEmpty || auth.appPassword.isEmpty)
                }

                if let error = auth.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section("How to create an app password") {
                    Text("In PhotoPrism, open Settings → Advanced → Apps, then create an app password. Use that password here rather than your normal PhotoPrism password.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PhotoVault")
        }
    }
}
