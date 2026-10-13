import CoreAudio
import Foundation

/// Liga um dispositivo virtual ao adaptador USB real através de um aggregate device privado.
/// O adaptador é o clock principal; o dispositivo virtual entra com drift compensation,
/// então não há deriva entre os dois clocks.
///
/// Dentro do IOProc: o primeiro buffer de entrada é copiado para o primeiro buffer de saída,
/// multiplicado por `gain`, passado pelo EQ, pelo crossfeed e pelo limitador (se houver) e por um limitador suave. Mono vira estéreo
/// duplicando o canal.
final class Bridge {
    let label: String
    /// Ganho linear lido na thread de tempo real. Escrito pela main thread; Float32 alinhado não "rasga".
    let gain: UnsafeMutablePointer<Float32>
    /// EQ opcional aplicado na saída; os ponteiros do kernel vivem enquanto o app viver.
    var eq: EQKernel?
    var crossfeed: CrossfeedKernel?
    /// Limitador de picos no fim da cadeia (usado só no fone).
    var limiter: LimiterKernel?

    private(set) var isRunning = false
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(label: String) {
        self.label = label
        gain = .allocate(capacity: 1)
        gain.initialize(to: 1)
    }

    deinit {
        stop()
        gain.deallocate()
    }

    /// `clockUID`: dispositivo real (clock principal). `virtualUID`: lado oculto do driver virtual.
    func start(clockUID: String, virtualUID: String) throws {
        stop()

        // Mesma taxa de amostragem nos dois lados evita conversão no aggregate.
        if let real = AudioHW.device(uid: clockUID), let virt = AudioHW.device(uid: virtualUID),
           let rate = AudioHW.nominalSampleRate(real), AudioHW.nominalSampleRate(virt) != rate {
            AudioHW.setNominalSampleRate(virt, rate)
        }

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Eolyra Bridge (\(label))",
            kAudioAggregateDeviceUIDKey: "app.eolyra.bridge.\(label).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceClockDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: clockUID, kAudioSubDeviceDriftCompensationKey: 0],
                [kAudioSubDeviceUIDKey: virtualUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        guard st == noErr else { throw BridgeError.coreAudio(L("create aggregate device"), st) }
        aggregate = agg

        let g = gain, eq = eq, xf = crossfeed, lim = limiter
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inData, _, outData, _ in
            Bridge.render(input: inData, output: outData, gain: g.pointee, eq: eq, crossfeed: xf, limiter: lim)
        }
        guard st == noErr else { stop(); throw BridgeError.coreAudio(L("create IOProc"), st) }

        st = AudioDeviceStart(agg, procID)
        guard st == noErr else { stop(); throw BridgeError.coreAudio(L("start IO"), st) }
        isRunning = true
        NSLog("[Eolyra] bridge %@ iniciada (in=%d ch, out=%d ch)", label,
              AudioHW.channelCount(agg, input: true), AudioHW.channelCount(agg, input: false))
    }

    func stop() {
        if aggregate != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggregate, p)
                AudioDeviceDestroyIOProcID(aggregate, p)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
            if isRunning { NSLog("[Eolyra] bridge %@ parada", label) }
        }
        procID = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    // Thread de tempo real: sem alocação, sem locks, sem ObjC.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gain: Float32, eq: EQKernel?, crossfeed: CrossfeedKernel?,
                               limiter: LimiterKernel?) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for b in outs where b.mData != nil { memset(b.mData, 0, Int(b.mDataByteSize)) }

        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let src = ins.first(where: { $0.mData != nil && $0.mNumberChannels > 0 }),
              let dst = outs.first(where: { $0.mData != nil && $0.mNumberChannels > 0 }),
              let sp = src.mData?.assumingMemoryBound(to: Float32.self),
              let dp = dst.mData?.assumingMemoryBound(to: Float32.self) else { return }

        let sCh = Int(src.mNumberChannels), dCh = Int(dst.mNumberChannels)
        let frames = min(Int(src.mDataByteSize) / (4 * sCh), Int(dst.mDataByteSize) / (4 * dCh))
        for f in 0..<frames {
            for c in 0..<dCh {
                dp[f * dCh + c] = sp[f * sCh + min(c, sCh - 1)] * gain
            }
        }
        eq?.process(dp, frames: frames, channels: dCh)
        crossfeed?.process(dp, frames: frames, channels: dCh)
        limiter?.process(dp, frames: frames, channels: dCh)
        for i in 0..<(frames * dCh) { dp[i] = softClip(dp[i]) }
    }
}

/// Linear até ±0.8; acima disso satura suavemente em direção a ±1 (evita o estalo do corte seco
/// quando o ganho extra do mic é alto).
@inline(__always)
private func softClip(_ x: Float32) -> Float32 {
    let knee: Float32 = 0.8
    let a = abs(x)
    guard a > knee else { return x }
    let y = knee + (1 - knee) * tanh((a - knee) / (1 - knee))
    return x < 0 ? -y : y
}

enum BridgeError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    var description: String {
        switch self {
        case let .coreAudio(what, st): return L("Failed to %@ (OSStatus %d)", what, Int(st))
        }
    }
}
