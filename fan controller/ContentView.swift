import SwiftUI

struct ContentView: View {
    @StateObject private var fanManager = FanManager()

    var body: some View {
        VStack(spacing: 16) {
            headerSection

            Divider()

            if !fanManager.isConnected {
                connectionErrorView
            } else if fanManager.fans.isEmpty {
                noFansView
            } else {
                fansSection
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: true, vertical: true)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            fanManager.resetToAuto()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "fan.fill")
                .font(.title2)
                .foregroundColor(.blue)

            Text("Fan Controller")
                .font(.title2.bold())

            Spacer()

            if fanManager.cpuTemperature > 0 {
                HStack(spacing: 4) {
                    Image(systemName: temperatureIcon)
                        .foregroundColor(temperatureColor)
                    Text(String(format: "%.1f°C", fanManager.cpuTemperature))
                        .font(.headline.monospacedDigit())
                }
            }
        }
    }

    // MARK: - States

    private var connectionErrorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("Cannot Connect to SMC")
                .font(.headline)
            Text(fanManager.errorMessage ?? "Unable to access the System Management Controller.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
    }

    private var noFansView: some View {
        VStack(spacing: 12) {
            Image(systemName: "fan.slash")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No Fans Detected")
                .font(.headline)
            Text("This Mac doesn't appear to have controllable fans.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if fanManager.cpuTemperature > 0 {
                Text(String(format: "CPU Temperature: %.1f°C", fanManager.cpuTemperature))
                    .font(.subheadline)
                    .padding(.top, 4)
            }
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Fan Controls

    private var fansSection: some View {
        VStack(spacing: 16) {
            ForEach(fanManager.fans) { fan in
                FanCard(
                    fan: fan,
                    isSelected: fanManager.selectedFans.contains(fan.id),
                    onToggle: { toggleFan(fan.id) }
                )
            }

            Divider()

            modeSection

            if fanManager.mode == .custom {
                customSliderSection
            }

            actionButtons

            if let error = fanManager.errorMessage {
                errorBanner(error)
            }

            if let log = fanManager.debugLog, !log.isEmpty {
                debugPanel(log)
            }
        }
    }

    private func debugPanel(_ log: String) -> some View {
        ScrollView {
            Text(log)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fan Mode")
                .font(.headline)

            Picker("Mode", selection: $fanManager.mode) {
                ForEach(FanMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(fanManager.mode.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var customSliderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target Speed")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(fanManager.customRPM)) RPM")
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .foregroundColor(.blue)
            }

            Slider(
                value: $fanManager.customRPM,
                in: fanManager.sliderMin...fanManager.sliderMax,
                step: 100
            )

            HStack {
                Text("\(Int(fanManager.sliderMin))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let maxFan = fanManager.fans.max(by: { $0.maxRPM < $1.maxRPM }) {
                    Text("Reported max: \(Int(maxFan.maxRPM))")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                Spacer()
                Text("\(Int(fanManager.sliderMax))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.orange.opacity(0.08))
        )
    }

    private var actionButtons: some View {
        HStack {
            Button {
                fanManager.applyMode()
            } label: {
                Label("Apply", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)

            Spacer()

            Button {
                fanManager.mode = .auto
                fanManager.applyMode()
            } label: {
                Label("Reset to Auto", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            Text(message)
                .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.red.opacity(0.1))
        )
    }

    private func toggleFan(_ id: Int) {
        if fanManager.selectedFans.contains(id) {
            fanManager.selectedFans.remove(id)
        } else {
            fanManager.selectedFans.insert(id)
        }
    }

    // MARK: - Temperature Helpers

    private var temperatureIcon: String {
        if fanManager.cpuTemperature > 80 { return "thermometer.sun.fill" }
        if fanManager.cpuTemperature > 50 { return "thermometer.medium" }
        return "thermometer.low"
    }

    private var temperatureColor: Color {
        if fanManager.cpuTemperature > 90 { return .red }
        if fanManager.cpuTemperature > 70 { return .orange }
        if fanManager.cpuTemperature > 50 { return .yellow }
        return .green
    }
}

// MARK: - Fan Card

struct FanCard: View {
    let fan: FanInfo
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Controlled by Apply" : "Not controlled")

                Label("Fan \(fan.id + 1)", systemImage: "fan.fill")
                    .font(.headline)
                Spacer()
                Text("\(Int(fan.currentRPM)) RPM")
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .foregroundColor(rpmColor)
            }

            ProgressView(
                value: min(fan.currentRPM, max(fan.maxRPM, 1)),
                total: max(fan.maxRPM, 1)
            )
            .tint(rpmColor)

            HStack {
                Text("Min: \(Int(fan.minRPM)) RPM")
                Spacer()
                Text("Max: \(Int(fan.maxRPM)) RPM")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .opacity(isSelected ? 1.0 : 0.6)
    }

    private var rpmColor: Color {
        let ratio = fan.maxRPM > 0 ? fan.currentRPM / fan.maxRPM : 0
        if ratio > 0.8 { return .red }
        if ratio > 0.5 { return .orange }
        return .green
    }
}

#Preview {
    ContentView()
}
