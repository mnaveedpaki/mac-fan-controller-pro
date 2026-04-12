import SwiftUI

@main
struct fan_controllerApp: App {
    init() {
        // When launched with --smc-helper, run as a privileged helper and exit
        if CommandLine.arguments.contains("--smc-helper") {
            SMCHelper.run()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
