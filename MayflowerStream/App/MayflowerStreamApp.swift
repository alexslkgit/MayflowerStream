//
//  MayflowerStreamApp.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import HaishinKit
import Logboard
import SwiftUI

@main
struct MayflowerStreamApp: App {
    init() {
        // HaishinKit narrates every format negotiation to the console at .info; the app's own
        // log is the one worth reading there.
        LBLogger.with(kHaishinKitIdentifier).level = .warn
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
