import SwiftUI

@main
struct ClipStageApp: App {
    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .preferredColorScheme(.dark)
        }
    }
}
