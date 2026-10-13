import AppKit

/// Desenha a resposta em frequência total do EQ (20 Hz–20 kHz, escala log, ±12 dB).
final class ResponseView: NSView {
    weak var equalizer: Equalizer?
    private let minF = 20.0, maxF = 20000.0, rangeDB = 15.0

    override var isFlipped: Bool { false }

    private func x(_ f: Double) -> CGFloat {
        CGFloat(log10(f / minF) / log10(maxF / minF)) * bounds.width
    }

    private func y(_ db: Double) -> CGFloat {
        bounds.midY + CGFloat(db / rangeDB) * (bounds.height / 2 - 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let grid = NSBezierPath()
        for db in [-12.0, -6, 6, 12] { grid.move(to: NSPoint(x: 0, y: y(db))); grid.line(to: NSPoint(x: bounds.width, y: y(db))) }
        for f in Equalizer.frequencies { grid.move(to: NSPoint(x: x(f), y: 0)); grid.line(to: NSPoint(x: x(f), y: bounds.height)) }
        NSColor.separatorColor.setStroke()
        grid.lineWidth = 0.5
        grid.stroke()

        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: 0, y: y(0))); zero.line(to: NSPoint(x: bounds.width, y: y(0)))
        NSColor.tertiaryLabelColor.setStroke()
        zero.lineWidth = 1
        zero.stroke()

        guard let eq = equalizer else { return }
        let curve = NSBezierPath()
        let steps = 200
        for i in 0...steps {
            let f = minF * pow(maxF / minF, Double(i) / Double(steps))
            let p = NSPoint(x: x(f), y: y(max(-rangeDB, min(rangeDB, eq.response(at: f)))))
            i == 0 ? curve.move(to: p) : curve.line(to: p)
        }
        (eq.enabled ? NSColor.controlAccentColor : NSColor.disabledControlTextColor).setStroke()
        curve.lineWidth = 2.5
        curve.lineJoinStyle = .round
        curve.stroke()
    }
}

final class EqualizerWindowController: NSWindowController {
    private let eq: Equalizer
    private let enableBox = NSButton(checkboxWithTitle: L("Enable equalizer"), target: nil, action: nil)
    private let presetPopup = NSPopUpButton()
    private let responseView = ResponseView()
    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []
    private let limiterLabel = NSTextField(labelWithString: "")

    init(equalizer: Equalizer) {
        eq = equalizer
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Equalizer — Eolyra")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        enableBox.target = self
        enableBox.action = #selector(toggleEnabled)
        presetPopup.target = self
        presetPopup.action = #selector(pickPreset)
        let reset = NSButton(title: L("Reset"), target: self, action: #selector(resetFlat))
        reset.bezelStyle = .rounded
        let presetLabel = NSTextField(labelWithString: L("Preset:"))
        let top = NSStackView(views: [enableBox, NSView(), presetLabel, presetPopup, reset])
        top.spacing = 8

        responseView.equalizer = eq

        let bands = NSStackView()
        bands.distribution = .fillEqually
        bands.spacing = 4
        for (i, f) in Equalizer.frequencies.enumerated() {
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.alignment = .center
            let slider = NSSlider(value: 0, minValue: Equalizer.range.lowerBound, maxValue: Equalizer.range.upperBound,
                                  target: self, action: #selector(sliderMoved(_:)))
            slider.isVertical = true
            slider.tag = i
            slider.numberOfTickMarks = 5
            slider.isContinuous = true
            let freq = NSTextField(labelWithString: f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
            freq.font = .systemFont(ofSize: 11, weight: .medium)
            freq.alignment = .center
            let col = NSStackView(views: [value, slider, freq])
            col.orientation = .vertical
            col.spacing = 4
            slider.heightAnchor.constraint(equalToConstant: 150).isActive = true
            bands.addArrangedSubview(col)
            sliders.append(slider)
            valueLabels.append(value)
        }

        limiterLabel.font = .systemFont(ofSize: 11)
        limiterLabel.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString:
            L("The EQ applies to audio played through the “Eolyra” device. The presets take advantage of the headset’s planar magnetic drivers, which handle bass boost with little distortion."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let root = NSStackView(views: [top, responseView, bands, limiterLabel, note])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            top.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            responseView.widthAnchor.constraint(equalTo: top.widthAnchor),
            responseView.heightAnchor.constraint(equalToConstant: 110),
            bands.widthAnchor.constraint(equalTo: top.widthAnchor),
            note.widthAnchor.constraint(equalTo: top.widthAnchor),
        ])
    }

    private func refresh() {
        enableBox.state = eq.enabled ? .on : .off
        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: Equalizer.presets.map(\.name))
        if let i = Equalizer.presets.firstIndex(where: { $0.id == eq.presetID }) {
            presetPopup.selectItem(at: i)
        } else {
            presetPopup.addItem(withTitle: eq.presetName)
            presetPopup.selectItem(at: Equalizer.presets.count)
        }
        for (i, s) in sliders.enumerated() {
            s.doubleValue = eq.gains[i]
            s.isEnabled = eq.enabled
            valueLabels[i].stringValue = Self.format(eq.gains[i])
        }
        presetPopup.isEnabled = eq.enabled
        limiterLabel.stringValue = L("A built-in limiter prevents clipping without lowering the overall volume.")
        responseView.needsDisplay = true
    }

    private static func format(_ db: Double) -> String {
        db == 0 ? "0" : String(format: "%+.0f", db)
    }

    @objc private func toggleEnabled() { eq.setEnabled(enableBox.state == .on); refresh() }

    @objc private func pickPreset() {
        let i = presetPopup.indexOfSelectedItem
        guard Equalizer.presets.indices.contains(i) else { return }
        eq.apply(preset: Equalizer.presets[i])
        refresh()
    }

    @objc private func resetFlat() { eq.apply(preset: Equalizer.presets[0]); refresh() }

    @objc private func sliderMoved(_ s: NSSlider) {
        eq.setGain(s.tag, s.doubleValue.rounded())
        refresh()
    }
}
