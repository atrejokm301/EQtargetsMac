//
//  ImportPreviewSheet.swift
//  EQtargets (iOS)
//
//  "Preview, then apply" (DESIGN §5.4, §6.5). Every import path lands here and
//  nothing changes until Apply Correction. Shows exactly what Apply will load,
//  plus what the file itself said, so a difference (dropped filters, a wrong
//  file preamp) is visible instead of silent.
//

import SwiftUI

struct ImportPreviewSheet: View {
    @State var preview: ImportPreview
    /// Called before dismissing, so the main screen opens the picker afterwards.
    let onChooseAnother: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch preview.result {
                case .success(let c): content(c)
                case .failure(let f): failure(f)
                }
            }
            .background(Palette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    // MARK: Success

    private func content(_ c: ImportedCorrection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview headphone correction").font(Typo.title).foregroundStyle(Palette.textPrimary)
                    Text("\(c.sourceName) \u{00B7} \(c.filtersInFile) filter\(c.filtersInFile == 1 ? "" : "s")")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        .lineLimit(2).truncationMode(.middle)
                }

                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s3) {
                        legend("New", dashed: false, color: Palette.targetStroke)
                        legend("Current", dashed: true, color: Palette.textSecondary)
                    }
                    MiniCurveView(new: c.layer, current: model.dual.target, sampleRate: model.graphSampleRate)
                        .frame(height: 140)
                }
                .eqtCard(padding: Space.s3)

                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Name").font(Typo.body).foregroundStyle(Palette.textSecondary)
                    TextField("Name", text: $preview.name)
                        .font(Typo.body)
                        .submitLabel(.done)
                        .padding(.horizontal, Space.s4)
                        .frame(minHeight: Space.touch)
                        .background(Capsule().fill(Palette.textPrimary.opacity(0.08)))
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("import.name")
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Preamp").font(Typo.body).foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Text(EQFormat.gain(c.measuredPreampDB)).font(Typo.value).foregroundStyle(Palette.textPrimary)
                    }
                    if c.preampDiffers, let file = c.filePreampDB {
                        Text("File said \(EQFormat.signedNumber(file, decimals: 1))\u{00A0}dB \u{2014} we measured \(EQFormat.signedNumber(c.measuredPreampDB, decimals: 1))\u{00A0}dB from the filters, which is what keeps it from clipping.")
                            .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                FilterTable(bands: Array(c.layer.bands.prefix(max(1, min(c.filtersInFile, EQLayerState.bandCount)))))
                    .eqtCard(padding: Space.s3)

                if !c.dropped.isEmpty {
                    Label {
                        Text("This file has \(c.filtersInFile) filters. EQtargets uses 10, so we kept the ones that shape the sound most. Dropped: \(c.droppedPreview).")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                    }
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                }

                if let device = model.currentOutput {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Use for \(device.name)").font(Typo.body).foregroundStyle(Palette.textPrimary)
                            Spacer(minLength: Space.s2)
                            Toggle("Use for \(device.name)", isOn: $preview.bindToCurrentOutput)
                                .labelsHidden()
                                .toggleStyle(PillSwitchStyle(tint: Palette.targetStroke))
                        }
                        Text("Loads automatically whenever \(device.name) is the output.")
                            .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Your tuning stays exactly as it is.")
                    .font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
            .padding(Space.s4)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            Button("Apply Correction") {
                model.applyImport(preview)
                dismiss()
            }
            .buttonStyle(PillButtonStyle(kind: .primary, fullWidth: true))
            .disabled(preview.name.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s1)
            .accessibilityIdentifier("import.apply")
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
            .accessibilityHidden(true)
            Text(title).font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: Failure

    private func failure(_ f: ImportFailure) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                Label {
                    Text(f.title).font(Typo.title).foregroundStyle(Palette.textPrimary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                }
                Text(f.message)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: "https://autoeq.app")!) {
                    Label("Find Your Headphones on AutoEQ", systemImage: "arrow.up.right")
                }
                .buttonStyle(PillButtonStyle())
                Button("Choose Another File\u{2026}") {
                    onChooseAnother()
                    dismiss()
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Filter table

private struct FilterTable: View {
    let bands: [EQBand]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.s2, verticalSpacing: Space.s1) {
            GridRow {
                Text("#")
                Text("Type")
                Text("Frequency").gridColumnAlignment(.trailing)
                Text("Gain").gridColumnAlignment(.trailing)
                Text("Q").gridColumnAlignment(.trailing)
            }
            .font(Typo.captionSemibold)
            .foregroundStyle(Palette.textSecondary)
            .accessibilityHidden(true)
            Divider()
            ForEach(bands.indices, id: \.self) { i in
                let b = bands[i]
                GridRow {
                    Text("\(i + 1)").foregroundStyle(Palette.textSecondary)
                    Text(b.filterType.shortTitle + (b.isEnabled ? "" : " (off)"))
                    Text(EQFormat.frequency(b.frequency))
                    Text(EQFormat.gain(b.gain))
                    Text(EQFormat.q(b.q))
                }
                .font(Typo.captionRounded)
                .foregroundStyle(b.isEnabled ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
