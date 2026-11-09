namespace KeyWoo.Core;

/// <summary>Linear display ranges over existing stored settings, without migrating or rounding preferences.</summary>
public readonly record struct ControlScale(double StoredMinimum, double StoredMaximum,
    double DisplayMinimum, double DisplayMaximum) {
    public static readonly ControlScale KeyboardVolume = new(0, 16, 0, 1);
    public static readonly ControlScale RhythmIntensity = new(0.4, 1.5, 0.25, 1);
    public const double DisplayStep = 0.01;

    public double DisplayValue(double storedValue) => Map(storedValue, StoredMinimum, StoredMaximum,
        DisplayMinimum, DisplayMaximum);

    public double StoredValue(double displayValue) => Map(displayValue, DisplayMinimum, DisplayMaximum,
        StoredMinimum, StoredMaximum);

    private static double Map(double value, double sourceMinimum, double sourceMaximum,
        double destinationMinimum, double destinationMaximum) {
        double bounded = double.IsNaN(value) ? sourceMinimum : Math.Clamp(value, sourceMinimum, sourceMaximum);
        double fraction = (bounded - sourceMinimum) / (sourceMaximum - sourceMinimum);
        return destinationMinimum + fraction * (destinationMaximum - destinationMinimum);
    }
}
