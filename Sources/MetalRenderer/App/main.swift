import Cocoa

// Line-buffer stdout so [bench] logging (see Renderer.logBenchmark) shows up
// live even when redirected to a file/pipe, instead of only on exit.
setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
