/// Linear UI ranges over existing stored values. Display changes never migrate
/// preferences or round a value until the user actually moves a control.
struct ControlScale: Sendable {
    let storedRange: ClosedRange<Double>
    let displayRange: ClosedRange<Double>

    static let keyboardVolume = ControlScale(storedRange: 0...16, displayRange: 0...1)
    static let rhythmIntensity = ControlScale(storedRange: 0.4...1.5, displayRange: 0.25...1)
    static let displayStep = 0.01

    func displayValue(for storedValue: Double) -> Double {
        Self.map(storedValue, from: storedRange, to: displayRange)
    }

    func storedValue(for displayValue: Double) -> Double {
        Self.map(displayValue, from: displayRange, to: storedRange)
    }

    private static func map(_ value: Double, from source: ClosedRange<Double>, to destination: ClosedRange<Double>) -> Double {
        let bounded = value.isNaN ? source.lowerBound : min(source.upperBound, max(source.lowerBound, value))
        let fraction = (bounded - source.lowerBound) / (source.upperBound - source.lowerBound)
        return destination.lowerBound + fraction * (destination.upperBound - destination.lowerBound)
    }
}
