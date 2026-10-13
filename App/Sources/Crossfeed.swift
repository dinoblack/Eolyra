import Foundation

/// Parte do crossfeed que roda na thread de tempo real: só ponteiros, sem ARC, sem alocação.
///
/// Eolyra Space: simula o que acontece com caixas de som, onde cada ouvido também ouve a caixa
/// oposta um pouco depois (atraso interaural) e com menos agudos (sombra da cabeça).
/// O processamento age só na diferença entre canais, S = L − R:
///
///     y  = passa-baixa(atraso(S))
///     L' = L − g·y
///     R' = R + g·y
///
/// Assim L' + R' = L + R: tudo o que está no centro (voz, diálogo) passa intacto, e só o que
/// está aberto para os lados ganha o "vazamento" atrasado e abafado para o ouvido oposto.
struct CrossfeedKernel {
    static let delaySize = 64  // amostras; cobre o atraso máximo até 96 kHz

    let params: UnsafeMutablePointer<Float32>  // [2 bancos][g, coefPassaBaixa, atrasoEmAmostras]
    let active: UnsafeMutablePointer<Int32>    // banco em uso; -1 = desligado
    let delay: UnsafeMutablePointer<Float32>   // linha de atraso de S
    let state: UnsafeMutablePointer<Float32>   // [índiceDeEscrita, saídaDoPassaBaixa]

    /// Processa áudio estéreo intercalado no lugar (canais além do 2º não são tocados).
    func process(_ buf: UnsafeMutablePointer<Float32>, frames: Int, channels: Int) {
        let bank = Int(active.pointee)
        guard bank >= 0, channels >= 2, frames > 0 else { return }
        let p = params + bank * 3
        let g = p[0], a = p[1], d = p[2]
        let n = Self.delaySize
        let whole = Int(d), frac = d - Float32(whole)
        var w = Int(state[0]), lp = state[1]
        var i = 0
        for _ in 0..<frames {
            let l = buf[i], r = buf[i + 1]
            delay[w] = l - r
            // Leitura com interpolação linear entre as duas amostras vizinhas ao atraso fracionário.
            let i0 = (w - whole + n) % n, i1 = (w - whole - 1 + n) % n
            let s = delay[i0] + (delay[i1] - delay[i0]) * frac
            lp += a * (s - lp)
            buf[i] = l - g * lp
            buf[i + 1] = r + g * lp
            w = (w + 1) % n
            i += channels
        }
        if abs(lp) < 1e-15 { lp = 0 }  // evita denormais no silêncio
        state[0] = Float32(w); state[1] = lp
    }
}

/// Crossfeed próprio do Eolyra ("Eolyra Space"), em três intensidades.
final class Crossfeed {
    struct Level { let name: String; let amount: Double; let cutoff: Double; let delayMs: Double }

    /// `amount` = quanto do lado oposto chega a cada ouvido nos graves; `cutoff` = sombra da cabeça;
    /// `delayMs` = atraso interaural.
    static let levels: [Level] = [
        Level(name: L("Off"), amount: 0, cutoff: 0, delayMs: 0),
        Level(name: L("Light"), amount: 0.20, cutoff: 650, delayMs: 0.22),
        Level(name: L("Medium"), amount: 0.30, cutoff: 750, delayMs: 0.28),
        Level(name: L("Strong"), amount: 0.42, cutoff: 850, delayMs: 0.34),
    ]

    let kernel: CrossfeedKernel
    private(set) var level: Int
    private(set) var sampleRate: Double = 48000
    private let defaults = UserDefaults.standard

    init() {
        kernel = CrossfeedKernel(params: .allocate(capacity: 6), active: .allocate(capacity: 1),
                                 delay: .allocate(capacity: CrossfeedKernel.delaySize), state: .allocate(capacity: 2))
        kernel.params.initialize(repeating: 0, count: 6)
        kernel.active.initialize(to: -1)
        kernel.delay.initialize(repeating: 0, count: CrossfeedKernel.delaySize)
        kernel.state.initialize(repeating: 0, count: 2)
        level = min(max(defaults.integer(forKey: "crossfeedLevel"), 0), Self.levels.count - 1)
        publish()
    }

    deinit {
        kernel.params.deallocate(); kernel.active.deallocate()
        kernel.delay.deallocate(); kernel.state.deallocate()
    }

    func setLevel(_ l: Int) {
        level = min(max(l, 0), Self.levels.count - 1)
        defaults.set(level, forKey: "crossfeedLevel")
        publish()
    }

    func setSampleRate(_ rate: Double) {
        guard rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        publish()
    }

    /// Escreve os parâmetros no banco inativo e troca o banco ativo (sem lock na thread de áudio).
    private func publish() {
        let l = Self.levels[level]
        guard l.amount > 0 else { kernel.active.pointee = -1; return }
        let bank = kernel.active.pointee == 0 ? 1 : 0
        let p = kernel.params + bank * 3
        p[0] = Float32(l.amount)
        p[1] = Float32(1 - exp(-2 * Double.pi * l.cutoff / sampleRate))  // passa-baixa de 1ª ordem
        p[2] = Float32(min(l.delayMs / 1000 * sampleRate, Double(CrossfeedKernel.delaySize - 2)))
        kernel.active.pointee = Int32(bank)
    }
}
