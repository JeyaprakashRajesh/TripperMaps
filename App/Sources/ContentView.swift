import SwiftUI
import MapKit

/// Deliberately tiny, glanceable UI: pick a destination (or free ride), then put the phone away.
struct ContentView: View {
    @EnvironmentObject var ride: RideController
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(ride.statusText).font(.headline)
                    if ride.isStreaming {
                        if let img = ride.preview {
                            // Exactly what is being sent: the 526×300 frame, masked by the round glass.
                            Image(decorative: img, scale: 1)
                                .resizable()
                                .aspectRatio(526.0 / 300.0, contentMode: .fit)
                                .mask(GeometryReader { g in
                                    let k = g.size.width / 526          // glass: centre (262,263), r 264
                                    Circle().frame(width: 528 * k, height: 528 * k)
                                        .position(x: 262 * k, y: 263 * k)
                                })
                                .accessibilityLabel("Live preview of the dash stream")
                        }
                        LabeledContent("Mode", value: ride.stats.tier)
                        LabeledContent("Dash FPS", value: String(format: "%.1f", ride.stats.fps))
                        LabeledContent("Bitrate", value: "\(ride.stats.kbps) kbps")
                        LabeledContent("Missing tiles", value: "\(ride.stats.missingTiles)")
                    }
                }

                Section("Options") {
                    Toggle("Dark map", isOn: $ride.darkMap).disabled(ride.isBusy)
                    Toggle("Turbo 12 fps (only while charging)", isOn: $ride.allowTurbo)
                }

                Section {
                    Toggle("Test mode: stream to PC", isOn: $ride.testMode).disabled(ride.isBusy)
                    if ride.testMode {
                        TextField("PC IP address", text: $ride.testHost)
                            .keyboardType(.decimalPad)
                            .disabled(ride.isBusy)
                    }
                    Toggle("Simulate ride (fake GPS)", isOn: $ride.simulateRide).disabled(ride.isBusy)
                    if ride.simulateRide {
                        Stepper("Speed \(Int(ride.simSpeedKmh)) km/h", value: $ride.simSpeedKmh, in: 10...100, step: 10)
                            .disabled(ride.isBusy)
                    }
                } header: {
                    Text("Testing without the bike")
                } footer: {
                    Text("Test mode skips the dash login and sends the video to your PC on UDP 5000. Open dash-preview.sdp in VLC or ffplay there.")
                }

                if !ride.isStreaming {
                    Section("Where to?") {
                        TextField("Search Apple Maps", text: $query)
                            .textInputAutocapitalization(.never)
                            .onSubmit { Task { await ride.search(query) } }
                        ForEach(ride.searchResults, id: \.self) { item in
                            Button {
                                Task { await ride.start(to: item) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "Place")
                                    Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Free ride (no route)") { Task { await ride.start(to: nil) } }
                    }
                } else {
                    Button("Stop", role: .destructive) { ride.stop() }
                }
            }
            .navigationTitle("TripperMaps")
        }
        .onChange(of: scenePhase) { _, phase in
            // Apple's snapshotter only renders in the foreground: use every unlock to top up tiles.
            if phase == .active { ride.topUpTiles() }
            ride.setForeground(phase == .active)
        }
    }
}
