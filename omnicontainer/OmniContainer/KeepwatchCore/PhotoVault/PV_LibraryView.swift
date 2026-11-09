import SwiftUI

struct PVLibraryView: View {
    @EnvironmentObject private var auth: PVAuthViewModel
    let client: PVPhotoPrismClient

    @State private var photos: [PVPhoto] = []
    @State private var previewToken: String?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedPhoto: PVPhoto?
    @State private var showUploader = false

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading && photos.isEmpty {
                    ProgressView("Loading library")
                        .padding(.top, 80)
                } else if let errorMessage {
                    ContentUnavailableView("Could not load photos", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else if photos.isEmpty {
                    ContentUnavailableView("No photos found", systemImage: "photo.on.rectangle")
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(photos) { photo in
                            Button {
                                selectedPhoto = photo
                            } label: {
                                PVAsyncPhotoImage(client: client, photo: photo, previewToken: previewToken)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                }
            }
            .searchable(text: $searchText, prompt: "Search photos")
            .onChange(of: searchText) { _, newValue in
                Task { await load(reset: true, query: newValue) }
            }
            .refreshable {
                await load(reset: true, query: searchText)
            }
            .navigationTitle("Photos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showUploader = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Sign out", role: .destructive) {
                            auth.signOut()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showUploader) {
                PVUploadView(client: client)
            }
            .navigationDestination(item: $selectedPhoto) { photo in
                PVPhotoDetailView(client: client, photo: photo, previewToken: previewToken)
            }
            .task {
                if photos.isEmpty {
                    await load(reset: true, query: "")
                }
            }
        }
    }

    private func load(reset: Bool, query: String) async {
        if reset {
            photos = []
        }

        isLoading = true
        errorMessage = nil

        do {
            let (result, token) = try await client.searchPhotos(query: query)
            previewToken = token ?? previewToken
            photos = result.models
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
