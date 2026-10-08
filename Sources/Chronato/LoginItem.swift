import ServiceManagement

/// "Open at login" through SMAppService. Registering only works for the
/// installed .app bundle; run from `.build` it throws, and Settings shows why.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
