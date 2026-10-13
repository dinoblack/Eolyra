import AppKit
import CoreAudio
import ServiceManagement

// UIDs definidos em Driver/EolyraDriver.c.
enum UIDs {
    static let fone = "app.eolyra.device.output"               // saída visível "Eolyra"
    static let foneBridge = "app.eolyra.device.output.bridge"  // entrada oculta (lida pela ponte)
    static let mic = "app.eolyra.device.mic"                   // entrada visível "Eolyra Mic"
    static let micBridge = "app.eolyra.device.mic.bridge"      // saída oculta (escrita pela ponte)
    static let ownPrefixes = ["app.eolyra."]
}

/// Descobre o adaptador, liga/desliga as pontes sob demanda e cuida dos dispositivos padrão.
final class Controller {
    struct State: Equatable {
        var psOut: AudioDeviceID?, psIn: AudioDeviceID?
        var fone: AudioDeviceID?, mic: AudioDeviceID?
        var psOutUID: String?, psInUID: String?
        var connected: Bool { psOut != nil || psIn != nil }
        var driversInstalled: Bool { fone != nil && mic != nil }
    }

    private(set) var state = State()
    let foneBridge = Bridge(label: "fone")
    let micBridge = Bridge(label: "mic")
    let equalizer = Equalizer()
    let crossfeed = Crossfeed()
    let limiter = LimiterKernel.make()
    var lastError: String?
    var onChange: (() -> Void)?

    private var listeners: [AudioHW.Listener] = []
    private var deviceListeners: [AudioHW.Listener] = []
    private let defaults = UserDefaults.standard

    var autoDefault: Bool {
        get { defaults.object(forKey: "autoDefault") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoDefault") }
    }

    var micBoostDB: Float {
        get { defaults.object(forKey: "micBoostDB") as? Float ?? 0 }
        set { defaults.set(newValue, forKey: "micBoostDB"); micBridge.gain.pointee = pow(10, newValue / 20) }
    }

    func start() {
        micBridge.gain.pointee = pow(10, micBoostDB / 20)
        foneBridge.eq = equalizer.kernel
        foneBridge.crossfeed = crossfeed.kernel
        foneBridge.limiter = limiter
        let sys = AudioHW.system
        listeners = [
            .init(sys, AudioHW.addr(kAudioHardwarePropertyDevices)) { [weak self] in self?.refresh() },
            .init(sys, AudioHW.addr(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.rememberDefaults() },
            .init(sys, AudioHW.addr(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in self?.rememberDefaults() },
        ]
        rememberDefaults()
        refresh(initial: true)
    }

    func shutdown() {
        foneBridge.stop()
        micBridge.stop()
        // Sem a ponte, os dispositivos virtuais ficam mudos: devolve o áudio ao adaptador real.
        restoreRealDefaults(preferPS: true)
    }

    // MARK: descoberta

    private func scan() -> State {
        var s = State()
        for id in AudioHW.deviceIDs() {
            guard let uid = AudioHW.uid(id) else { continue }
            if uid == UIDs.fone { s.fone = id; continue }
            if uid == UIDs.mic { s.mic = id; continue }
            let name = AudioHW.name(id) ?? ""
            guard name.contains("PlayStation Link") || uid.contains("PlayStation Link") else { continue }
            if AudioHW.channelCount(id, input: false) > 0 { s.psOut = id; s.psOutUID = uid }
            if AudioHW.channelCount(id, input: true) > 0 { s.psIn = id; s.psInUID = uid }
        }
        return s
    }

    private func refresh(initial: Bool = false) {
        let old = state
        state = scan()

        if state != old || initial {
            // IDs mudaram: reinstala os listeners de "em uso" nos dispositivos virtuais.
            deviceListeners = [state.fone, state.mic].compactMap { $0 }.map {
                .init($0, AudioHW.addr(kAudioDevicePropertyDeviceIsRunningSomewhere)) { [weak self] in self?.reconcile() }
            }
            deviceListeners += levelListeners()
            if state.driversInstalled && (old.fone != state.fone || old.mic != state.mic) {
                restoreLevels()
            }
            if state.connected && (!old.connected || initial) && state.driversInstalled && autoDefault {
                useBridgeAsDefault()
                // Ao plugar, o macOS às vezes elege o adaptador como padrão logo depois de nós: reaplica.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.state.connected, self.autoDefault else { return }
                    let out = AudioHW.defaultDevice(.output), inp = AudioHW.defaultDevice(.input)
                    if out == self.state.psOut || inp == self.state.psIn { self.useBridgeAsDefault() }
                }
            }
            if !state.connected && (old.connected || initial) {
                // Desplugou (ou abrimos sem o adaptador, ex.: após reboot): sem ponte não há som.
                restoreRealDefaults(preferPS: false)
            }
        }
        reconcile()
    }

    // MARK: volumes persistentes
    // O driver volta a 100% sempre que o coreaudiod reinicia (reboot); guardamos e restauramos.

    private struct Level { let key: String; let input: Bool; let mute: Bool }
    private let levels = [Level(key: "foneVolume", input: false, mute: false), Level(key: "foneMute", input: false, mute: true),
                          Level(key: "micVolume", input: true, mute: false), Level(key: "micMute", input: true, mute: true)]

    private func levelListeners() -> [AudioHW.Listener] {
        levels.compactMap { l in
            guard let dev = l.input ? state.mic : state.fone else { return nil }
            let sel = l.mute ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar
            return .init(dev, AudioHW.addr(sel, l.input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)) { [weak self] in
                guard let self else { return }
                if l.mute { self.defaults.set(AudioHW.isMuted(dev, input: l.input), forKey: l.key) }
                else if let v = AudioHW.volume(dev, input: l.input) { self.defaults.set(v, forKey: l.key) }
                self.onChange?()
            }
        }
    }

    private func restoreLevels() {
        for l in levels {
            guard let dev = l.input ? state.mic : state.fone else { continue }
            if defaults.object(forKey: l.key) == nil {
                // Primeira execução: guarda o valor atual.
                if l.mute { defaults.set(AudioHW.isMuted(dev, input: l.input), forKey: l.key) }
                else if let v = AudioHW.volume(dev, input: l.input) { defaults.set(v, forKey: l.key) }
            } else if l.mute { AudioHW.setMuted(dev, input: l.input, defaults.bool(forKey: l.key)) }
            else { AudioHW.setVolume(dev, input: l.input, defaults.float(forKey: l.key)) }
        }
    }

    /// Liga cada ponte só quando algum app está usando o dispositivo virtual correspondente.
    func reconcile() {
        lastError = nil
        sync(foneBridge, want: state.fone.map(AudioHW.isRunningSomewhere) ?? false,
             clock: state.psOutUID, virtual: UIDs.foneBridge)
        sync(micBridge, want: state.mic.map(AudioHW.isRunningSomewhere) ?? false,
             clock: state.psInUID, virtual: UIDs.micBridge)
        onChange?()
    }

    private func sync(_ bridge: Bridge, want: Bool, clock: String?, virtual: String) {
        if want, let clock {
            guard !bridge.isRunning else { return }
            if bridge === foneBridge, let dev = AudioHW.device(uid: clock), let rate = AudioHW.nominalSampleRate(dev) {
                equalizer.setSampleRate(rate)
                crossfeed.setSampleRate(rate)
                limiter.setSampleRate(rate)
            }
            do { try bridge.start(clockUID: clock, virtualUID: virtual) } catch {
                lastError = "\(bridge.label): \(error)"
                NSLog("[Eolyra] %@", lastError!)
            }
        } else if bridge.isRunning {
            bridge.stop()
        }
    }

    // MARK: dispositivos padrão

    private func isOwnOrPS(_ dev: AudioDeviceID) -> Bool {
        guard let uid = AudioHW.uid(dev) else { return true }
        return UIDs.ownPrefixes.contains { uid.hasPrefix($0) } || uid.contains("PlayStation Link")
    }

    /// Guarda o último dispositivo "de verdade" escolhido, para voltar a ele quando o headset sair.
    private func rememberDefaults() {
        if let d = AudioHW.defaultDevice(.output), !isOwnOrPS(d), let uid = AudioHW.uid(d) {
            defaults.set(uid, forKey: "fallbackOutput")
        }
        if let d = AudioHW.defaultDevice(.input), !isOwnOrPS(d), let uid = AudioHW.uid(d) {
            defaults.set(uid, forKey: "fallbackInput")
        }
        onChange?()
    }

    func useBridgeAsDefault() {
        if let fone = state.fone, state.psOut != nil {
            AudioHW.setDefaultDevice(.output, fone)
            AudioHW.setDefaultDevice(.system, fone)
        }
        if let mic = state.mic, state.psIn != nil {
            AudioHW.setDefaultDevice(.input, mic)
        }
    }

    private func restoreRealDefaults(preferPS: Bool) {
        func pick(_ role: AudioHW.Role, ps: AudioDeviceID?, key: String, input: Bool) -> AudioDeviceID? {
            if preferPS, let ps { return ps }
            if let uid = defaults.string(forKey: key), let d = AudioHW.device(uid: uid) { return d }
            return AudioHW.deviceIDs().first {
                !isOwnOrPS($0) && AudioHW.channelCount($0, input: input) > 0
                    && (AudioHW.get($0, AudioHW.addr(kAudioDevicePropertyIsHidden), UInt32(0)) ?? 0) == 0
            }
        }
        let curOut = AudioHW.defaultDevice(.output)
        if curOut != nil, curOut == state.fone, let d = pick(.output, ps: state.psOut, key: "fallbackOutput", input: false) {
            AudioHW.setDefaultDevice(.output, d)
        }
        if let cur = AudioHW.defaultDevice(.system), cur == state.fone,
           let d = pick(.system, ps: state.psOut, key: "fallbackOutput", input: false) {
            AudioHW.setDefaultDevice(.system, d)
        }
        if let cur = AudioHW.defaultDevice(.input), cur == state.mic,
           let d = pick(.input, ps: state.psIn, key: "fallbackInput", input: true) {
            AudioHW.setDefaultDevice(.input, d)
        }
    }
}

// MARK: - Interface (barra de menus)

final class SliderRow: NSView {
    let slider: NSSlider
    let valueLabel = NSTextField(labelWithString: "")
    var format: (Double) -> String
    var onChange: ((Double) -> Void)?

    init(title: String, min: Double, max: Double, format: @escaping (Double) -> String) {
        self.format = format
        slider = NSSlider(value: 0, minValue: min, maxValue: max, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .menuFont(ofSize: 13)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        for v in [titleLabel, valueLabel, slider] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ v: Double?, enabled: Bool = true) {
        slider.isEnabled = enabled && v != nil
        if let v { slider.doubleValue = v }
        valueLabel.stringValue = v.map(format) ?? "—"
    }

    @objc private func changed() {
        valueLabel.stringValue = format(slider.doubleValue)
        onChange?(slider.doubleValue)
    }
}

/// Cabeçalho do menu: qual adaptador está conectado e o que está ativo.
final class HeaderView: NSView {
    enum Status { case connected, disconnected, problem }

    private let icon = NSImageView()
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        icon.image = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = .labelColor
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        for v in [icon, dot, title, subtitle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            dot.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, subtitle s: String, status: Status) {
        title.stringValue = t
        subtitle.stringValue = s
        let color: NSColor = status == .connected ? .systemGreen : (status == .problem ? .systemOrange : .tertiaryLabelColor)
        dot.layer?.backgroundColor = color.cgColor
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = Controller()
    var statusItem: NSStatusItem!
    let menu = NSMenu()

    let header = HeaderView()
    let foneRow = SliderRow(title: L("Headphones"), min: 0, max: 1) { "\(Int(($0 * 100).rounded()))%" }
    let foneMute = NSMenuItem(title: L("Mute headphones"), action: #selector(toggleFoneMute), keyEquivalent: "")
    let micRow = SliderRow(title: L("Microphone"), min: 0, max: 1) { "\(Int(($0 * 100).rounded()))%" }
    let boostRow = SliderRow(title: L("Extra mic gain"), min: 0, max: 40) { String(format: "+%.0f dB", $0) }
    let micMute = NSMenuItem(title: L("Mute microphone"), action: #selector(toggleMicMute), keyEquivalent: "")
    let autoItem = NSMenuItem(title: L("Use Eolyra as default when connected"), action: #selector(toggleAuto), keyEquivalent: "")
    let loginItem = NSMenuItem(title: L("Open at login"), action: #selector(toggleLogin), keyEquivalent: "")
    let eqItem = NSMenuItem(title: L("Equalizer…"), action: #selector(openEqualizer), keyEquivalent: "e")
    lazy var eqWindow = EqualizerWindowController(equalizer: controller.equalizer)
    let crossfeedItem = NSMenuItem(title: L("Crossfeed"), action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        statusItem.menu = menu
        controller.onChange = { [weak self] in self?.updateIcon() }
        controller.start()
        updateIcon()
        enableLoginItemOnFirstRun()
        // Usado para gerar os screenshots do README: `open Eolyra.app --args --show-menu`.
        if CommandLine.arguments.contains("--show-eq") { eqWindow.show() }
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.statusItem.button?.performClick(nil) }
        }
    }

    /// Sem o app rodando, o "Eolyra" fica mudo; por isso ele abre no login por padrão (desligável no menu).
    private func enableLoginItemOnFirstRun() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch { NSLog("[Eolyra] login item: %@", "\(error)") }
    }

    func applicationWillTerminate(_ n: Notification) { controller.shutdown() }

    private func buildMenu() {
        menu.delegate = self
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())

        foneRow.onChange = { [weak self] v in
            if let d = self?.controller.state.fone { AudioHW.setVolume(d, input: false, Float(v)) }
        }
        micRow.onChange = { [weak self] v in
            if let d = self?.controller.state.mic { AudioHW.setVolume(d, input: true, Float(v)) }
        }
        boostRow.onChange = { [weak self] v in self?.controller.micBoostDB = Float(v.rounded()) }

        for (view, item) in [(foneRow, foneMute), (micRow, micMute)] as [(NSView, NSMenuItem)] {
            let vi = NSMenuItem(); vi.view = view; menu.addItem(vi)
            item.target = self; menu.addItem(item)
            if view === foneRow {
                eqItem.target = self; menu.addItem(eqItem)
                let sub = NSMenu()
                for (i, l) in Crossfeed.levels.enumerated() {
                    let it = NSMenuItem(title: l.name, action: #selector(pickCrossfeed(_:)), keyEquivalent: "")
                    it.target = self; it.tag = i; sub.addItem(it)
                }
                sub.addItem(.separator())
                let hint = NSMenuItem(title: L("Blends the bass between sides, like speakers do,"), action: nil, keyEquivalent: "")
                let hint2 = NSMenuItem(title: L("reducing fatigue on long listening sessions."), action: nil, keyEquivalent: "")
                hint.isEnabled = false; hint2.isEnabled = false
                sub.addItem(hint); sub.addItem(hint2)
                crossfeedItem.submenu = sub
                menu.addItem(crossfeedItem)
            }
            if view === micRow { let b = NSMenuItem(); b.view = boostRow; menu.addItem(b) }
            menu.addItem(.separator())
        }

        let now = NSMenuItem(title: L("Set Eolyra as default now"), action: #selector(useNow), keyEquivalent: "")
        for i in [now, autoItem, loginItem] { i.target = self; menu.addItem(i) }
        menu.addItem(.separator())
        let sound = NSMenuItem(title: L("Sound Settings…"), action: #selector(openSound), keyEquivalent: "")
        sound.target = self
        menu.addItem(sound)
        menu.addItem(NSMenuItem(title: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) {
        let s = controller.state
        // Nome real do adaptador, como o macOS o informa (ex.: "PlayStation Link Adapter").
        let adapter = (s.psOut ?? s.psIn).flatMap(AudioHW.name) ?? "PlayStation Link Adapter"
        if !s.driversInstalled {
            header.set(title: adapter, subtitle: L("Drivers not installed (run scripts/install.sh)"), status: .problem)
        } else if !s.connected {
            header.set(title: adapter, subtitle: L("Disconnected — plug in the USB adapter"), status: .disconnected)
        } else {
            var parts = [L("Connected")]
            if controller.foneBridge.isRunning { parts.append(L("headphones active")) }
            if controller.micBridge.isRunning { parts.append(L("mic active")) }
            if let e = controller.lastError { parts.append(L("error: %@", e)) }
            header.set(title: adapter, subtitle: parts.joined(separator: " · "), status: controller.lastError == nil ? .connected : .problem)
        }
        foneRow.set(s.fone.flatMap { AudioHW.volume($0, input: false) }.map(Double.init))
        micRow.set(s.mic.flatMap { AudioHW.volume($0, input: true) }.map(Double.init))
        boostRow.set(Double(controller.micBoostDB))
        foneMute.state = s.fone.map { AudioHW.isMuted($0, input: false) } == true ? .on : .off
        micMute.state = s.mic.map { AudioHW.isMuted($0, input: true) } == true ? .on : .off
        autoItem.state = controller.autoDefault ? .on : .off
        let eq = controller.equalizer
        let xf = controller.crossfeed.level
        crossfeedItem.title = L("Crossfeed: %@", Crossfeed.levels[xf].name)
        for it in crossfeedItem.submenu?.items ?? [] where it.action != nil { it.state = it.tag == xf ? .on : .off }
        eqItem.title = eq.enabled ? L("Equalizer: %@…", eq.presetName) : L("Equalizer (off)…")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func updateIcon() {
        let s = controller.state
        let muted = s.fone.map { AudioHW.isMuted($0, input: false) } ?? false
        let img = Bundle.main.image(forResource: muted ? "MenuBarMuted" : "MenuBar")
            ?? NSImage(systemSymbolName: "headphones", accessibilityDescription: "Eolyra")
        img?.isTemplate = true
        img?.accessibilityDescription = "Eolyra"
        statusItem.button?.image = img
        statusItem.button?.appearsDisabled = !s.connected
    }

    @objc private func toggleFoneMute() {
        guard let d = controller.state.fone else { return }
        AudioHW.setMuted(d, input: false, !AudioHW.isMuted(d, input: false))
        updateIcon()
    }

    @objc private func toggleMicMute() {
        guard let d = controller.state.mic else { return }
        AudioHW.setMuted(d, input: true, !AudioHW.isMuted(d, input: true))
    }

    @objc private func openEqualizer() { eqWindow.show() }
    @objc private func pickCrossfeed(_ item: NSMenuItem) { controller.crossfeed.setLevel(item.tag) }

    @objc private func useNow() { controller.useBridgeAsDefault() }
    @objc private func toggleAuto() { controller.autoDefault.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("[Eolyra] login item: %@", "\(error)") }
    }

    @objc private func openSound() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
