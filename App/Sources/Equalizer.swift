import Foundation

/// Parte do EQ que roda na thread de tempo real: só ponteiros, sem ARC, sem alocação.
struct EQKernel {
    static let bands = 10
    static let maxChannels = 2

    let coeffs: UnsafeMutablePointer<Float32>  // [2 bancos][bands][b0 b1 b2 a1 a2]
    let active: UnsafeMutablePointer<Int32>    // banco em uso; -1 = EQ desligado
    let state: UnsafeMutablePointer<Float32>   // [maxChannels][bands][x1 x2 y1 y2]

    /// Filtra `buf` (Float32 intercalado) no lugar.
    func process(_ buf: UnsafeMutablePointer<Float32>, frames: Int, channels: Int) {
        let bank = Int(active.pointee)
        guard bank >= 0, frames > 0 else { return }
        let c = coeffs + bank * Self.bands * 5
        for ch in 0..<min(channels, Self.maxChannels) {
            var i = ch
            for b in 0..<Self.bands {
                let k = c + b * 5
                let st = state + (ch * Self.bands + b) * 4
                let b0 = k[0], b1 = k[1], b2 = k[2], a1 = k[3], a2 = k[4]
                if b0 == 1, b1 == 0, b2 == 0, a1 == 0, a2 == 0 { continue }  // banda em 0 dB
                var x1 = st[0], x2 = st[1], y1 = st[2], y2 = st[3]
                i = ch
                for _ in 0..<frames {
                    let x = buf[i]
                    let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                    x2 = x1; x1 = x; y2 = y1; y1 = y
                    buf[i] = y
                    i += channels
                }
                // Evita denormais no silêncio (custam caro em CPUs Intel).
                if abs(y1) < 1e-15 { y1 = 0 }
                if abs(y2) < 1e-15 { y2 = 0 }
                st[0] = x1; st[1] = x2; st[2] = y1; st[3] = y2
            }
        }
    }
}

/// EQ gráfico de 10 bandas (filtros peaking biquad, ~1 oitava cada) com presets e persistência.
final class Equalizer {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let range: ClosedRange<Double> = -12...12
    static let q = 1.41

    struct Preset { let id: String; let name: String; let gains: [Double] }

    /// Presets pensados para drivers planar magnéticos (graves fortes com pouca distorção).
    static let presets: [Preset] = [
        Preset(id: "flat", name: L("Flat"), gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(id: "bass", name: L("Bass"), gains: [6, 5, 3, 1, 0, 0, 0, 0, 0, 0]),
        Preset(id: "games", name: L("Games (footsteps)"), gains: [-2, -2, -1, 0, 0, 1, 3, 4, 2, 0]),
        Preset(id: "music", name: L("Music"), gains: [4, 3, 1, 0, -1, -1, 0, 2, 3, 3]),
        Preset(id: "movies", name: L("Movies"), gains: [5, 4, 2, 0, 0, 1, 2, 1, 1, 0]),
        Preset(id: "voice", name: L("Voice / calls"), gains: [-4, -3, -1, 0, 1, 2, 3, 2, 0, -1]),
    ]
    static let customID = "custom"

    let kernel: EQKernel
    private(set) var sampleRate: Double = 48000
    private let defaults = UserDefaults.standard

    private(set) var gains: [Double]
    private(set) var enabled: Bool

    /// O preset é deduzido dos ganhos, então não depende do idioma nem fica dessincronizado.
    var presetID: String { Self.presets.first { $0.gains == gains }?.id ?? Self.customID }
    var presetName: String { Self.presets.first { $0.id == presetID }?.name ?? L("Custom") }

    init() {
        kernel = EQKernel(coeffs: .allocate(capacity: 2 * EQKernel.bands * 5),
                          active: .allocate(capacity: 1),
                          state: .allocate(capacity: EQKernel.maxChannels * EQKernel.bands * 4))
        kernel.coeffs.initialize(repeating: 0, count: 2 * EQKernel.bands * 5)
        kernel.active.initialize(to: -1)
        kernel.state.initialize(repeating: 0, count: EQKernel.maxChannels * EQKernel.bands * 4)

        let saved = (defaults.array(forKey: "eqGains") as? [NSNumber])?.map(\.doubleValue)
        gains = saved?.count == EQKernel.bands ? saved! : Self.presets[0].gains
        enabled = defaults.object(forKey: "eqEnabled") as? Bool ?? false
        publish()
    }

    deinit {
        kernel.coeffs.deallocate()
        kernel.active.deallocate(); kernel.state.deallocate()
    }

    func setEnabled(_ on: Bool) { enabled = on; save(); publish() }

    func setGain(_ band: Int, _ db: Double) {
        gains[band] = min(Self.range.upperBound, max(Self.range.lowerBound, db))
        save(); publish()
    }

    func apply(preset: Preset) {
        gains = preset.gains
        save(); publish()
    }

    func setSampleRate(_ rate: Double) {
        guard rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        publish()
    }

    /// Resposta total (dB) em `freq`, para desenhar a curva.
    func response(at freq: Double) -> Double {
        let w = 2 * Double.pi * freq / sampleRate
        var total = 0.0
        for (f, g) in zip(Self.frequencies, gains) where g != 0 {
            let c = Self.peaking(f: f, db: g, fs: sampleRate)
            // |H(e^jw)|² de um biquad
            let cw = cos(w), c2w = cos(2 * w)
            let num = c.b0 * c.b0 + c.b1 * c.b1 + c.b2 * c.b2 + 2 * (c.b0 * c.b1 + c.b1 * c.b2) * cw + 2 * c.b0 * c.b2 * c2w
            let den = 1 + c.a1 * c.a1 + c.a2 * c.a2 + 2 * (c.a1 + c.a1 * c.a2) * cw + 2 * c.a2 * c2w
            total += 10 * log10(num / den)
        }
        return total
    }

    // MARK: privado

    private struct Coeffs { var b0, b1, b2, a1, a2: Double }

    private static func peaking(f: Double, db: Double, fs: Double) -> Coeffs {
        guard db != 0, f < fs / 2 else { return Coeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0) }
        let a = pow(10, db / 40)
        let w0 = 2 * Double.pi * f / fs
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha / a
        return Coeffs(b0: (1 + alpha * a) / a0, b1: -2 * cos(w0) / a0, b2: (1 - alpha * a) / a0,
                      a1: -2 * cos(w0) / a0, a2: (1 - alpha / a) / a0)
    }

    /// Escreve os coeficientes no banco inativo e troca o banco ativo (sem lock na thread de áudio).
    private func publish() {
        guard enabled else { kernel.active.pointee = -1; return }
        let bank = kernel.active.pointee == 0 ? 1 : 0
        let dst = kernel.coeffs + bank * EQKernel.bands * 5
        for (b, (f, g)) in zip(Self.frequencies, gains).enumerated() {
            let c = Self.peaking(f: f, db: g, fs: sampleRate)
            let k = dst + b * 5
            k[0] = Float32(c.b0); k[1] = Float32(c.b1); k[2] = Float32(c.b2); k[3] = Float32(c.a1); k[4] = Float32(c.a2)
        }
        kernel.active.pointee = Int32(bank)
    }

    private func save() {
        defaults.set(gains, forKey: "eqGains")
        defaults.removeObject(forKey: "eqPreset")  // versões antigas guardavam o nome
        defaults.set(enabled, forKey: "eqEnabled")
    }
}
