import SwiftUI
import SwiftData

@main
struct LibreChatApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let dependencies: AppDependencies
    @State private var model: AppModel

    init() {
        #if DEBUG
        let dependencies = ProcessInfo.processInfo.arguments.contains("-ui-test-fixtures")
            ? AppDependencies.uiTestFixtures()
            : AppDependencies.live()
        #else
        let dependencies = AppDependencies.live()
        #endif
        self.dependencies = dependencies
        _model = State(initialValue: AppModel(dependencies: dependencies))
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(model: model)
                .modelContainer(dependencies.modelContainer)
                .environment(\.fetchServerImage, ServerImageFetchAction { url in
                    try? await model.imageData(at: url)
                })
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    // One transition emits .inactive then .background; only
                    // the active→inactive edge may count, or a single scene
                    // decrements the aggregate twice.
                    if newPhase == .active, oldPhase != .active {
                        model.sceneBecameActive()
                    }
                    if oldPhase == .active, newPhase != .active {
                        model.sceneResignedActive()
                    }
                }
        }
    }
}
