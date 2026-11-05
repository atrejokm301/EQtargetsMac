//
//  ImportPreviewSheet.swift
//  EQtargets (macOS)
//
//  "Preview, then apply" (DESIGN §5.4, §6.5). Every import path lands here;
//  nothing changes until Apply Correction. Shows exactly what Apply will load —
//  the whole-file `AutoEQParser.parse` result — plus what the file itself said,
//  so a difference (dropped filters, a wrong file preamp) is visible, not silent.
//

import SwiftUI

struct ImportPreviewSheet: View {
    @State var preview: ImportPreview
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch preview.result {
            case .success(let c): content(c)
            case .failure(let f): failure(f)
            }
        }
        .padding(Space.s6)
        .frame(width: 520)
    }

    // MARK: Success

    private func content(_ c: ImportedCorrection) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview headphone correction").font(Typo.title)
                Text("\(c.sourceName) \u{00B7} \(c.filtersInFile) filter\(c.filtersInFile == 1 ? "" : "s")")
                    .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s3) {
                    legend("New", dashed: false, color: Palette.targetStroke)
                    legend("Current", dashed: true, color: Palette.textSecondary)
                }
                MiniCurveView(new: c.layer, current: model.dual.target, sampleRate: model.display.graphSampleRate)
                    .frame(height: 120)
            }
            .eqtCard(padding: Space.s3)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s3, verticalSpacing: Space.s2) {
                GridRow {
                    Text("Name").font(Typo.body).foregroundStyle(Palette.textSecondary)
                    TextField("Name", text: $preview.name)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                GridRow {
                    Text("Preamp").font(Typo.body).foregroundStyle(Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(EQFormat.gain(c.measuredPreampDB)).font(Typo.value)
                        if c.preampDiffers, let file = c.filePreampDB {
                            Text("File said \(EQFormat.signedNumber(file, decimals: 1))\u{00A0}dB \u{2014} we measured \(EQFormat.signedNumber(c.measuredPreampDB, decimals: 1))\u{00A0}dB from the filters, which is what keeps it from clipping.")
                                .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            FilterTable(bands: Array(c.layer.bands.prefix(max(1, min(c.filtersInFile, EQLayerState.bandCount)))))
                .frame(height: 28 + 24 * CGFloat(min(max(c.filtersInFile, 1), EQLayerState.bandCount)) + 2)

            if !c.dropped.isEmpty {
                Label {
                    Text("This file has \(c.filtersInFile) filters. EQtargets uses 10, so we kept the ones that shape the sound most. Dropped: \(c.droppedSummary).")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            }

            if let device = model.display.currentOutput {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Use for \(device.name)", isOn: $preview.bindToCurrentOutput)
                        .toggleStyle(.checkbox)
                    Text("Loads automatically whenever \(device.name) is the output.")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        .padding(.leading, 20)
                }
            }

            Text("Your tuning stays exactly as it is.")
                .font(Typo.caption).foregroundStyle(Palette.textSecondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply Correction") {
                    model.applyImport(preview)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func legend(_ title: String, dashed: Bool, color: Color) -> some View {
        HStack(spacing: 6) {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [5, 4] : []))
            }
            .frame(width: 16, height: 4)
            Text(title).font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: Failure

    private func failure(_ f: ImportFailure) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Label {
                Text(f.title).font(Typo.title)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            }
            Text(f.message)
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Find Your Headphones on AutoEQ \u{2197}", destination: URL(string: "https://autoeq.app")!)
                .font(Typo.body)
            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Another File\u{2026}") {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        model.showFileImporter = true
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Filter table

private struct FilterTable: View {
    struct Row: Identifiable { let id: Int; let band: EQBand }
    let bands: [EQBand]

    var body: some View {
        Table(bands.enumerated().map { Row(id: $0.offset, band: $0.element) }) {
            TableColumn("#") { r in Text("\(r.id + 1)").monospacedDigit() }.width(24)
            TableColumn("Type") { r in Text(r.band.filterType.title) }.width(min: 70, ideal: 84)
            TableColumn("Frequency") { r in Text(EQFormat.frequency(r.band.frequency)).monospacedDigit() }.width(min: 70, ideal: 84)
            TableColumn("Gain") { r in Text(EQFormat.gain(r.band.gain)).monospacedDigit() }.width(min: 60, ideal: 70)
            TableColumn("Q") { r in Text(EQFormat.q(r.band.q)).monospacedDigit() }.width(min: 40, ideal: 48)
            TableColumn("On") { r in Image(systemName: r.band.isEnabled ? "checkmark" : "minus").foregroundStyle(Palette.textSecondary) }.width(28)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .font(Typo.body)
    }
}

// MARK: - Mini curve (same math as the main graph, no nodes, not interactive)

struct MiniCurveView: View {
    let new: EQLayerState
    let current: EQLayerState
    let sampleRate: Double

    var body: some View {
        let a = ResponseMath.layerCurve(new, sampleRate: sampleRate, count: 256)
        let b = ResponseMath.layerCurve(current, sampleRate: sampleRate, count: 256)
        let span = max(12, ceil(max(ResponseMath.maxAbs(a.db), ResponseMath.maxAbs(b.db)) / 6) * 6)
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { CGFloat(FrequencyResponse.xPosition(f)) * size.width }
            func y(_ db: Double) -> CGFloat { size.height / 2 - CGFloat(db / span) * (size.height / 2 - 4) }
            var grid = Path()
            for f in GraphGeometry.majorFrequencies {
                grid.move(to: CGPoint(x: x(f), y: 0)); grid.addLine(to: CGPoint(x: x(f), y: size.height))
            }
            ctx.stroke(grid, with: .color(Palette.textPrimary.opacity(0.08)), lineWidth: 0.5)
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(zero, with: .color(Palette.textPrimary.opacity(0.3)), lineWidth: 1)
            func line(_ freqs: [Double], _ v: [Double]) -> Path {
                var p = Path()
                for (i, f) in freqs.enumerated() {
                    let pt = CGPoint(x: x(f), y: y(v[i]))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            ctx.stroke(line(b.freqs, b.db), with: .color(Palette.textSecondary),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
            ctx.stroke(line(a.freqs, a.db), with: .color(Palette.targetStroke),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("Preview curve of the new correction against the current one")
    }
}
