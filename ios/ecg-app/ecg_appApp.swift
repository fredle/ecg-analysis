import SwiftUI
import SwiftData

@main
struct ecg_appApp: App {
    @State private var coordinator = ECGCoordinator()
    @State private var uploadQueue = UploadQueue()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Recording.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
                .environment(uploadQueue)
                .onAppear {
                    coordinator.attach(context: sharedModelContainer.mainContext)
                    uploadQueue.attach(context: sharedModelContainer.mainContext)
                    uploadQueue.kick()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
