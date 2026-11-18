import SwiftUI

@main
struct MultimusicApp: App {
    @StateObject private var music = MusicSession()

    var body: some Scene {
        WindowGroup { ContentView(music: music) }
    }
}
