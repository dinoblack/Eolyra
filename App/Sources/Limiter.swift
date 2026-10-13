import Foundation

/// Limitador de picos da saída do fone (thread de tempo real: só ponteiros, sem alocação).
///
/// Ataque instantâneo: se uma amostra passaria do teto, o ganho cai na hora o suficiente para ela
/// ficar exatamente no teto. Depois o ganho volta a 1 devagar (release), então ele só atua nos
/// instantes em que o EQ realmente estouraria, em vez de abaixar o volume o tempo todo.
struct LimiterKernel {
    static let ceiling: Float32 = 0.8  // abaixo do joelho do limitador suave da ponte

    let state: UnsafeMutablePointer<Float32>  // [ganho atual, coeficiente de release]

    static func make() -> LimiterKernel {
        let k = LimiterKernel(state: .allocate(capacity: 2))
        k.state.initialize(repeating: 1, count: 2)
        k.setSampleRate(48000)
        return k
    }

    /// Release de ~150 ms (mais longo que um ciclo de 32 Hz, para não deformar a onda).
    func setSampleRate(_ rate: Double) {
        state[1] = Float32(exp(-1 / (0.150 * rate)))
    }

    func process(_ buf: UnsafeMutablePointer<Float32>, frames: Int, channels: Int) {
        var g = state[0]
        let rel = state[1], ceiling = Self.ceiling
        var i = 0
        for _ in 0..<frames {
            var peak: Float32 = 0
            for c in 0..<channels { peak = max(peak, abs(buf[i + c])) }
            g = 1 - (1 - g) * rel                       // volta devagar para 1
            if peak * g > ceiling { g = ceiling / peak }  // ataque instantâneo
            for c in 0..<channels { buf[i + c] *= g }
            i += channels
        }
        state[0] = g
    }
}
