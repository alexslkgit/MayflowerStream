import SwiftUI

struct RootView: View {
    var body: some View {
        StreamConfigurationView(store: KeychainStreamSettingsStore())
    }
}

#Preview {
    RootView()
}
