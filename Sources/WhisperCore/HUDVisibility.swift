/// Completion tokens prevent an old fade-out from hiding a newer recording.
public struct HUDVisibility {
    public private(set) var visible = false
    public private(set) var generation: UInt64 = 0
    public init() {}

    public mutating func request(visible: Bool) -> UInt64? {
        guard self.visible != visible else { return nil }
        self.visible = visible
        generation &+= 1
        return generation
    }

    public func shouldHide(completedGeneration: UInt64) -> Bool {
        !visible && completedGeneration == generation
    }
}
