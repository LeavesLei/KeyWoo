import Testing
@testable import KeyDance

struct ControlScaleTests {
    @Test func volumeUsesTheWholeLinearRangeAndKeepsRecommendedGain() {
        let scale = ControlScale.keyboardVolume
        #expect(scale.displayValue(for: 0) == 0)
        #expect(scale.displayValue(for: 8) == 0.5)
        #expect(scale.displayValue(for: 16) == 1)
        #expect(scale.storedValue(for: 0) == 0)
        #expect(scale.storedValue(for: 0.5) == 8)
        #expect(scale.storedValue(for: 1) == 16)
        #expect(scale.displayValue(for: 1) == 0.0625,
                "Reset keeps the existing gain of 1 and displays it as 6.25%, not maximum volume.")
        #expect(scale.storedValue(for: 0.0625) == 1)
    }

    @Test func animationMapsExistingEndpointsAndMidpointToTheNewDisplayRange() {
        let scale = ControlScale.rhythmIntensity
        #expect(scale.displayValue(for: 0.4) == 0.25)
        #expect(scale.displayValue(for: 1.5) == 1)
        #expect(abs(scale.displayValue(for: 0.95) - 0.625) < 1e-12)
        #expect(scale.storedValue(for: 0.25) == 0.4)
        #expect(scale.storedValue(for: 1) == 1.5)
        #expect(abs(scale.storedValue(for: 0.625) - 0.95) < 1e-12)
    }

    @Test func existingValuesRoundTripWithoutQuantizingPreferences() {
        for stored in [0.0, 0.5, 1, 1.6, 3.75, 4, 8, 12.34567, 16] {
            let scale = ControlScale.keyboardVolume
            #expect(abs(scale.storedValue(for: scale.displayValue(for: stored)) - stored) < 1e-12)
        }
        for stored in [0.4, 0.55, 0.83, 0.95, 1, 1.234567, 1.5] {
            let scale = ControlScale.rhythmIntensity
            #expect(abs(scale.storedValue(for: scale.displayValue(for: stored)) - stored) < 1e-12)
        }
    }

    @Test func everyDisplayedPercentHasTheSameStoredStep() {
        let volume = ControlScale.keyboardVolume
        for index in 0..<100 {
            let lower = volume.storedValue(for: Double(index) * ControlScale.displayStep)
            let upper = volume.storedValue(for: Double(index + 1) * ControlScale.displayStep)
            #expect(abs((upper - lower) - 0.16) < 1e-12)
        }
        let intensity = ControlScale.rhythmIntensity
        for index in 25..<100 {
            let lower = intensity.storedValue(for: Double(index) * ControlScale.displayStep)
            let upper = intensity.storedValue(for: Double(index + 1) * ControlScale.displayStep)
            #expect(abs((upper - lower) - 1.1 / 75) < 1e-12)
        }
    }
}
