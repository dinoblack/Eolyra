// Teste de loopback do Eolyra.driver: escreve uma senoide num lado de cada par e mede o RMS
// recebido no outro lado, com volume 100%, 50% e mute.
// Uso: swiftc -O -o loopback App/Sources/AudioHW.swift Driver/Tests/Loopback/main.swift && ./loopback
import CoreAudio
import Foundation

final class Probe {
    var phase = 0.0, sumSq = 0.0, count = 0
    let freq = 1000.0, amp: Float32 = 0.5
}

func runPair(writerUID: String, readerUID: String, controlUID: String, controlIsInput: Bool) -> Bool {
    guard let w = AudioHW.device(uid: writerUID), let r = AudioHW.device(uid: readerUID),
          let ctl = AudioHW.device(uid: controlUID) else { print("  dispositivos não encontrados"); return false }
    let rate = AudioHW.nominalSampleRate(w) ?? 48000
    let savedVol = AudioHW.volume(ctl, input: controlIsInput) ?? 1
    let savedMute = AudioHW.isMuted(ctl, input: controlIsInput)
    defer { AudioHW.setVolume(ctl, input: controlIsInput, savedVol); AudioHW.setMuted(ctl, input: controlIsInput, savedMute) }

    let probe = Probe()
    var wProc: AudioDeviceIOProcID?, rProc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&wProc, w, nil) { _, _, _, out, _ in
        for b in UnsafeMutableAudioBufferListPointer(out) {
            guard let p = b.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let ch = Int(b.mNumberChannels), frames = Int(b.mDataByteSize) / 4 / ch
            for f in 0..<frames {
                let v = probe.amp * Float32(sin(probe.phase))
                probe.phase += 2 * .pi * probe.freq / rate
                for c in 0..<ch { p[f * ch + c] = v }
            }
        }
    }
    AudioDeviceCreateIOProcIDWithBlock(&rProc, r, nil) { _, inp, _, _, _ in
        for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp)) {
            guard let p = b.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let n = Int(b.mDataByteSize) / 4
            for i in 0..<n { probe.sumSq += Double(p[i] * p[i]) }
            probe.count += n
        }
    }
    AudioDeviceStart(w, wProc); AudioDeviceStart(r, rProc)

    var ok = true
    let ideal = Double(probe.amp) / 2.0.squareRoot()
    for (label, vol, mute, expected) in [("volume 100%", Float(1), false, 1.0), ("volume 50%", 0.5, false, 0.125), ("mute", 1, true, 0.0)] {
        AudioHW.setVolume(ctl, input: controlIsInput, vol); AudioHW.setMuted(ctl, input: controlIsInput, mute)
        Thread.sleep(forTimeInterval: 0.4)
        probe.sumSq = 0; probe.count = 0
        Thread.sleep(forTimeInterval: 0.8)
        let rms = probe.count > 0 ? (probe.sumSq / Double(probe.count)).squareRoot() : 0
        let ratio = rms / ideal
        let pass = abs(ratio - expected) < 0.03 && probe.count > 0
        ok = ok && pass
        print(String(format: "  %-12@ ganho medido %.3f (esperado %.3f)  %@", label as NSString, ratio, expected, pass ? "OK" : "FALHOU"))
    }
    AudioDeviceStop(w, wProc); AudioDeviceStop(r, rProc)
    AudioDeviceDestroyIOProcID(w, wProc!); AudioDeviceDestroyIOProcID(r, rProc!)
    return ok
}

print("par fone (Eolyra -> bridge):")
let a = runPair(writerUID: "app.eolyra.device.output", readerUID: "app.eolyra.device.output.bridge",
                controlUID: "app.eolyra.device.output", controlIsInput: false)
print("par mic (bridge -> Eolyra Mic):")
let b = runPair(writerUID: "app.eolyra.device.mic.bridge", readerUID: "app.eolyra.device.mic",
                controlUID: "app.eolyra.device.mic", controlIsInput: true)
print(a && b ? "RESULTADO: OK" : "RESULTADO: FALHOU")
exit(a && b ? 0 : 1)
