//
//  StreamViewTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import SwiftUI
import Testing

@testable import MayflowerStream

@Suite("When the broadcast is torn down for a scene phase change")
struct StreamViewTests {

    @Test("Backgrounding shuts the broadcast down")
    func backgroundShutsDown() {
        #expect(StreamView.shouldShutDown(on: .background))
    }

    @Test("Inactive does not shut the broadcast down")
    func inactiveDoesNotShutDown() {
        #expect(!StreamView.shouldShutDown(on: .inactive))
    }

    @Test("Active does not shut the broadcast down")
    func activeDoesNotShutDown() {
        #expect(!StreamView.shouldShutDown(on: .active))
    }
}
