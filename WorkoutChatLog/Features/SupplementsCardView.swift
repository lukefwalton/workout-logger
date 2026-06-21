import SwiftUI

/// A "Supplements today" card for the Today tab: tap to check off Creatine, Protein,
/// or any custom supplement; Protein takes an optional grams amount; long-press a
/// custom one to remove it. Backed by the SQLite store, so the checks become daily
/// history that trends in Progress. The checks reset each day.
///
/// NOTE: written correctly-by-inspection — not run in a simulator here; first real
/// verification is an Xcode/device launch.
struct SupplementsCardView: View {
    @StateObject private var model: SupplementModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAdd = false
    @State private var newName = ""

    init(store: WorkoutStore) {
        _model = StateObject(wrappedValue: SupplementModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Supplements today", systemImage: "pills.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    newName = ""
                    model.addError = nil
                    showingAdd = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(Theme.ocean)
                }
                .accessibilityLabel("Add supplement")
            }

            VStack(spacing: 8) {
                ForEach(model.supplements) { supplement in
                    row(for: supplement)
                        .contextMenu {
                            if !supplement.isPreset {
                                Button(role: .destructive) {
                                    model.removeSupplement(supplement.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                }
            }

            if let addError = model.addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let storeError = model.storeError {
                Label(storeError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Resets each day · saved on this phone · trends in Progress")
                .font(.caption2)
                .foregroundStyle(Theme.steel)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
        }
        .shadow(color: Theme.deepSea.opacity(0.10), radius: 24, y: 14)
        .onAppear { model.refreshForToday() }
        .onChange(of: scenePhase) { _, phase in
            // Clear yesterday's checks when the app returns to the foreground across
            // midnight, not only when the card first appears.
            if phase == .active { model.refreshForToday() }
        }
        .alert("Add supplement", isPresented: $showingAdd) {
            TextField("e.g. Vitamin D", text: $newName)
                .textInputAutocapitalization(.words)
            Button("Add") { _ = model.addSupplement(named: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add your own supplement to check off each day. Long-press one to remove it.")
        }
    }

    private func row(for supplement: Supplement) -> some View {
        let taken = model.isTaken(supplement.id)
        return HStack(spacing: 10) {
            Button { model.toggle(supplement.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: taken ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(taken ? Theme.kelp : Theme.steel)
                    Text(supplement.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ink)
                        .strikethrough(taken, color: Theme.steel)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(taken ? [.isButton, .isSelected] : .isButton)

            if supplement.tracksGrams && taken {
                gramsField(for: supplement)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(taken ? Theme.kelp.opacity(0.12) : Theme.paper.opacity(0.85),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func gramsField(for supplement: Supplement) -> some View {
        HStack(spacing: 4) {
            TextField("0", value: Binding(
                get: { model.grams(supplement.id) ?? 0 },
                set: { model.setGrams(supplement.id, grams: $0 > 0 ? $0 : nil) }),
                format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .accessibilityLabel("\(supplement.name) grams")
            Text("g")
                .font(.subheadline)
                .foregroundStyle(Theme.steel)
        }
    }
}
