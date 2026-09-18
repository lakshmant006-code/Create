import SwiftUI
import UIKit

struct ExportView: View {
    var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if viewModel.isExporting {
                    ProgressView(value: viewModel.exportProgress)
                        .progressViewStyle(.linear)
                    Text("\(Int(viewModel.exportProgress * 100))%")
                        .font(.headline)
                } else if let url = viewModel.exportedFileURL {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Export complete")
                        .font(.headline)
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share Video", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .sheet(isPresented: $showShareSheet) {
                        ActivityShareSheet(items: [url])
                    }
                } else {
                    Text("Exports as an H.264 MP4, matching the canvas you set up in the editor.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await viewModel.export() }
                    } label: {
                        Label("Start Export", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding()
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Thin wrapper around UIActivityViewController for sharing/saving the
/// exported file (Files, Photos, AirDrop, Messages, etc.).
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
