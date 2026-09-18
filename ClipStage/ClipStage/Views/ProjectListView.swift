import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ProjectListView: View {
    @State private var projects: [VideoProject] = ProjectStore.loadProjects()
    @State private var showPhotosPicker = false
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var activeProject: VideoProject?
    @State private var importTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if projects.isEmpty && !isImporting {
                    ContentUnavailableView(
                        "No projects yet",
                        systemImage: "film.stack",
                        description: Text("Import a screen recording or any video to start editing.")
                    )
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(projects) { project in
                            ProjectCard(project: project) {
                                activeProject = project
                            } onDelete: {
                                delete(project)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(Color.black)
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(projects.count) TOTAL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Browse Files", systemImage: "folder")
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.up")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isImporting)
                }
            }
            .overlay {
                if isImporting {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Importing…")
                            .font(.subheadline)
                        Text("Downloading from Photos can take a while over a slow connection.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 220)
                        Button("Cancel", role: .cancel) {
                            cancelImport()
                        }
                        .font(.footnote)
                        .padding(.top, 4)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Import failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $photosPickerItem, matching: .videos)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: false
            ) { result in
                handleFileImporterResult(result)
            }
            .onChange(of: photosPickerItem) { _, newValue in
                guard let newValue else { return }
                handlePhotosPickerSelection(newValue)
            }
            .navigationDestination(item: $activeProject) { project in
                EditorView(viewModel: EditorViewModel(
                    project: project,
                    sourceURL: ProjectStore.sourceURL(forFilename: project.sourceFilename)
                ))
                .onDisappear { refreshProjects() }
            }
        }
    }

    private func refreshProjects() {
        projects = ProjectStore.loadProjects()
    }

    private func delete(_ project: VideoProject) {
        ProjectStore.deleteProject(project)
        projects.removeAll { $0.id == project.id }
        ProjectStore.save(projects)
    }

    private func handlePhotosPickerSelection(_ item: PhotosPickerItem) {
        isImporting = true
        importTask = Task {
            do {
                guard let transferable = try await item.loadTransferable(type: VideoTransferable.self) else {
                    throw ImportError.couldNotLoad
                }
                guard !Task.isCancelled else { return }
                // transferable.url is our own disposable temp file (see
                // VideoTransferable) — safe to move into place instead of
                // copying, unlike a Files-importer URL.
                try await finishImport(from: transferable.url, name: defaultName(), ownsSource: true)
                photosPickerItem = nil
            } catch {
                guard !Task.isCancelled else { return }
                importError = error.localizedDescription
                isImporting = false
            }
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            let didAccess = url.startAccessingSecurityScopedResource()
            importTask = Task {
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard !Task.isCancelled else { return }
                    try await finishImport(from: url, name: url.deletingPathExtension().lastPathComponent)
                } catch {
                    guard !Task.isCancelled else { return }
                    importError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    /// Lets the user escape a stuck or slow import instead of being stuck
    /// on the overlay with no way out. Doesn't guarantee the underlying
    /// download/copy stops immediately, but the UI is unblocked right away
    /// and the cancelled task won't navigate anywhere when it does finish.
    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        isImporting = false
        photosPickerItem = nil
    }

    /// Imports the video, saves it into the project list, then jumps
    /// straight into the editor for it — no extra tap on the grid needed.
    @MainActor
    private func finishImport(from url: URL, name: String, ownsSource: Bool = false) async throws {
        let project = try await ProjectStore.importVideo(from: url, name: name, ownsSource: ownsSource)
        // A Photos import in particular (the underlying iCloud download,
        // if the original isn't on-device yet) can take a while, long
        // enough for cancelImport() to have already cancelled this task
        // and dismissed the "Importing…" overlay by the time it returns.
        // Without this check, a successful-but-late result would still
        // save the project and jump into the editor — right after the
        // user explicitly cancelled and watched the overlay go away.
        // (Thumbnail generation no longer factors in here — it now runs
        // in the background after this call already returns.)
        guard !Task.isCancelled else {
            ProjectStore.deleteProject(project)
            throw CancellationError()
        }
        var updated = ProjectStore.loadProjects()
        updated.append(project)
        ProjectStore.save(updated)
        projects = updated
        isImporting = false
        activeProject = project
    }

    private func defaultName() -> String {
        "Recording \(projects.count + 1)"
    }

    private enum ImportError: LocalizedError {
        case couldNotLoad
        var errorDescription: String? { "Couldn't read that video." }
    }
}

/// One card in the project grid: thumbnail, duration badge, name, date,
/// OPEN button — modeled on the reference screenshot's project browser.
private struct ProjectCard: View {
    let project: VideoProject
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .clipped()

                Text(formattedDuration)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(project.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: onOpen) {
                    Text("OPEN")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.top, 6)
            }
            .padding(12)
        }
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let filename = project.thumbnailFilename,
           let uiImage = UIImage(contentsOfFile: ProjectStore.thumbnailURL(forFilename: filename).path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color.black.opacity(0.85))
                .overlay {
                    Image(systemName: "video.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.6))
                }
        }
    }

    private var formattedDuration: String {
        let seconds = Int(project.trimmedDuration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Bridges a PhotosPicker video selection into a local file URL we own.
/// `received.file` is only valid inside this closure, so it has to be
/// relocated somewhere longer-lived before returning — moved rather than
/// copied, since it's already a disposable export PhotosPicker made just
/// for us (the real asset in Photos is untouched either way), and moving
/// is a fast rename instead of a full byte-for-byte duplicate of what can
/// be a very large file.
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { exported in
            SentTransferredFile(exported.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory.appending(path: "picked-\(UUID().uuidString).mov")
            try FileManager.default.moveItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}
