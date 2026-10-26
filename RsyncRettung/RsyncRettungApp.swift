//
//  RsyncRettungApp.swift
//  RsyncRettung
//
//  Created by Mustafa Sibak on 02.03.26.
//

import SwiftUI

@main
struct RsyncRettungApp: App {
    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 640, height: 860)
        .windowResizability(.contentMinSize)
    }
}
