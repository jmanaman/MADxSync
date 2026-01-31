import SwiftUI
import CoreLocation

/// Unified treatment sheet for marking locations on the map
/// Combines larvae inspection + treatment in one interface
struct TreatmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let coordinate: CLLocationCoordinate2D
    let onSave: (FieldMarker) -> Void
    
    // Larvae
    @State private var larvaeLevel: LarvaeLevel? = nil
    @State private var pupaePresent = false
    
    // Treatment
    @State private var family: TreatmentFamily = .field
    @State private var status: TreatmentStatus = .treated
    @State private var selectedChemical: ChemicalData.Chemical? = nil
    @State private var doseValue: String = ""
    @State private var doseUnit: DoseUnit = .flOz
    @State private var trapNumber: String = ""
    
    // Notes
    @State private var notes: String = ""
    
    // UI State
    @State private var showChemicalPicker = false
    
    var body: some View {
        NavigationView {
            Form {
                // Location header
                Section {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(.red)
                        VStack(alignment: .leading) {
                            Text("Location")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                
                // Larvae Section
                Section(header: Text("Larvae Found")) {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(LarvaeLevel.allCases) { level in
                            larvaePill(level)
                        }
                    }
                    
                    Toggle(isOn: $pupaePresent) {
                        Label("Pupae present", systemImage: "circle.circle")
                    }
                }
                
                // Treatment Section
                Section(header: Text("Treatment")) {
                    // Family picker
                    Picker("Type", selection: $family) {
                        ForEach(TreatmentFamily.allCases) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    // Status
                    Picker("Status", selection: $status) {
                        ForEach(TreatmentStatus.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    // Trap number (only for TRAP family)
                    if family == .trap {
                        HStack {
                            Text("Trap #")
                            TextField("e.g. 12", text: $trapNumber)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    
                    // Chemical (only if treated)
                    if status == .treated {
                        Button(action: { showChemicalPicker = true }) {
                            HStack {
                                Text("Chemical")
                                Spacer()
                                Text(selectedChemical?.name ?? "Select...")
                                    .foregroundColor(selectedChemical == nil ? .secondary : .primary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.primary)
                        
                        // Dose
                        HStack {
                            Text("Dose")
                            TextField("0.0", text: $doseValue)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Picker("", selection: $doseUnit) {
                                ForEach(DoseUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 80)
                        }
                        
                        // Quick dose presets
                        if let chemical = selectedChemical {
                            dosePresets(for: chemical)
                        }
                    }
                }
                
                // Notes Section
                Section(header: Text("Notes")) {
                    TextField("Optional notes...", text: $notes)
                }
            }
            .navigationTitle("Mark Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveMarker() }
                        .bold()
                }
            }
            .sheet(isPresented: $showChemicalPicker) {
                ChemicalPickerView(selected: $selectedChemical)
            }
        }
    }
    
    // MARK: - Larvae Pill
    private func larvaePill(_ level: LarvaeLevel) -> some View {
        Button(action: {
            if larvaeLevel == level {
                larvaeLevel = nil  // Deselect
            } else {
                larvaeLevel = level
            }
        }) {
            Text(level.displayName)
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    larvaeLevel == level
                        ? Color(hex: level.color)
                        : Color(.secondarySystemBackground)
                )
                .foregroundColor(larvaeLevel == level ? .white : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Dose Presets
    @ViewBuilder
    private func dosePresets(for chemical: ChemicalData.Chemical) -> some View {
        // Common dose presets based on chemical type
        let presets: [(String, Double, DoseUnit)] = {
            switch chemical.name {
            case "BTI Sand":
                return [("1 lb", 1, .lb), ("2 lb", 2, .lb), ("5 lb", 5, .lb)]
            case "Mosquitofish":
                return [("25", 25, .each), ("50", 50, .each), ("100", 100, .each)]
            case _ where chemical.name.contains("Natular"):
                return [("1 pouch", 1, .pouch), ("2 pouch", 2, .pouch)]
            case _ where chemical.name.contains("Altosid"):
                return [("1 briq", 1, .briq), ("2 briq", 2, .briq)]
            default:
                return [("4 oz", 4, .oz), ("8 oz", 8, .oz), ("16 oz", 16, .oz)]
            }
        }()
        
        HStack(spacing: 8) {
            ForEach(presets, id: \.0) { preset in
                Button(preset.0) {
                    doseValue = String(preset.1)
                    doseUnit = preset.2
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(6)
            }
        }
    }
    
    // MARK: - Save
    private func saveMarker() {
        let marker = FieldMarker(
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            family: family.rawValue,
            status: status.rawValue,
            chemical: selectedChemical?.name,
            doseValue: Double(doseValue),
            doseUnit: doseUnit.rawValue,
            trapNumber: family == .trap ? trapNumber : nil,
            larvae: larvaeLevel?.rawValue,
            pupaePresent: pupaePresent,
            notes: notes.isEmpty ? nil : notes
        )
        
        onSave(marker)
        dismiss()
    }
}

// MARK: - Chemical Picker
struct ChemicalPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: ChemicalData.Chemical?
    @State private var searchText = ""
    
    var filteredChemicals: [ChemicalData.Chemical] {
        if searchText.isEmpty {
            return ChemicalData.all
        }
        return ChemicalData.all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                // None option
                Button(action: {
                    selected = nil
                    dismiss()
                }) {
                    HStack {
                        Text("None")
                            .foregroundColor(.secondary)
                        Spacer()
                        if selected == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                
                // Grouped by category
                ForEach(ChemicalData.byCategory, id: \.category) { group in
                    Section(header: Text(group.category.rawValue)) {
                        ForEach(group.chemicals.filter {
                            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                        }) { chemical in
                            Button(action: {
                                selected = chemical
                                dismiss()
                            }) {
                                HStack {
                                    Text(chemical.name)
                                    Spacer()
                                    if selected?.id == chemical.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search chemicals")
            .navigationTitle("Select Chemical")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview
#Preview {
    TreatmentSheet(
        coordinate: CLLocationCoordinate2D(latitude: 36.2077, longitude: -119.3473)
    ) { marker in
        print("Saved marker: \(marker)")
    }
}
