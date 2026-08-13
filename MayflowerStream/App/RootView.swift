//
//  RootView.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import SwiftUI

struct RootView: View {
    var body: some View {
        StreamConfigurationView(store: KeychainStreamSettingsStore())
    }
}

#Preview {
    RootView()
}
