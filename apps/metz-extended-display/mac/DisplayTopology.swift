import CoreGraphics

struct DisplayState {
    let active: Bool
    let mirrored: Bool
    let builtIn: Bool
    let width: Int
    let height: Int

    init?(active: Int32, mirrored: Int32, builtIn: Int32, width: Int, height: Int) {
        // CG boolean_t queries return -1 for an unknown display on the
        // target macOS. Treat that as unavailable, never as true or independent.
        guard (0...1).contains(active), (0...1).contains(mirrored), (0...1).contains(builtIn) else { return nil }
        self.active = active == 1
        self.mirrored = mirrored == 1
        self.builtIn = builtIn == 1
        self.width = width
        self.height = height
    }
    var independent720p: Bool { matches(.conservative) }
    func matches(_ mode: StreamMode) -> Bool { active && !mirrored && width == mode.width && height == mode.height }
}

enum DisplayModeChoice {
    static func matches(width: Int, height: Int, rate: Double, requested: StreamMode) -> Bool {
        width == requested.width && height == requested.height && rate.isFinite &&
            (rate == 0 || abs(rate - Double(requested.fps)) < 1)
    }
}

enum DisplayTopology {
    private static func onlineDisplays() -> [CGDirectDisplayID]? {
        // Fetch the current list first: a just-created display ID can precede
        // registration in Quartz's topology. Queries before that return error flags.
        var displays = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
            Int(count) <= displays.count else { return nil }
        return Array(displays.prefix(Int(count)))
    }
    static func contains(_ id: CGDirectDisplayID) -> Bool? {
        onlineDisplays().map { $0.contains(id) }
    }
    static func state(of id: CGDirectDisplayID) -> DisplayState? {
        guard id != kCGNullDirectDisplay, contains(id) == true else { return nil }
        return DisplayState(active: CGDisplayIsActive(id), mirrored: CGDisplayIsInMirrorSet(id),
            builtIn: CGDisplayIsBuiltin(id), width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
    }
}
