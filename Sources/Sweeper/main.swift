import AppKit

let args = CommandLine.arguments

if args.contains("--selftest") {
    selfTest()
    exit(0)
}

if args.contains("--auto") {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await AutoSweep.run()
        done.signal()
    }
    done.wait()
    exit(0)
}

NSApplication.shared.setActivationPolicy(.regular)
SweeperApp.main()
