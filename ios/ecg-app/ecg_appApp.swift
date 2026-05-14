import SwiftUI
import SwiftData

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == BackgroundUploader.sessionIdentifier {
            BackgroundUploader.shared.systemCompletionHandler = completionHandler
            // Access .session to ensure the delegate is connected
            _ = BackgroundUploader.shared.session
        }
    }
}

@main
struct ecg_appApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
