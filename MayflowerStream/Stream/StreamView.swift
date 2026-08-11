import SwiftUI

/// Screen 2 — Main Stream. Placeholder: the capture and broadcast pieces land in the next commits.
struct StreamView: View {
    let endpoint: StreamEndpoint

    var body: some View {
        ContentUnavailableView(
            "Not built yet",
            systemImage: "video.slash",
            description: Text(endpoint.connectURL)
        )
        .navigationTitle("Broadcast")
        .navigationBarTitleDisplayMode(.inline)
    }
}
