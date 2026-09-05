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
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        model.sceneBecameActive()
                    case .inactive, .background:
                        model.sceneResignedActive()
                    @unknown default:
                        model.sceneResignedActive()
                    }
                }
        }
    }
}
