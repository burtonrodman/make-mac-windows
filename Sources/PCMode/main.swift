import Cocoa

// PCMode runs as a background "agent" app: no dock icon, no menu bar app
// switcher entry, just a status item. Activation policy must be set before
// the run loop starts.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
