import SwiftUI

@main
struct MacSanityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { model.showIcon },
            set: { model.setHideIcon(!$0) }
        )) {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.menuBarSymbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}
