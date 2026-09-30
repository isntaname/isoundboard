import SwiftUI

@main
struct SoundboardApp: App {
    @State private var model: AppModel

    init() {
        Migration.run()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("iSoundboard", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 620, height: 780)
    }
}
