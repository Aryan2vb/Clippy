import SwiftUI
import Foundation

// MARK: - Memory Info Model

struct MemoryInfo {
    let totalRAM: UInt64
    let availableRAM: UInt64
    let usedByFiles: Int64

    var usedRAM: UInt64 { totalRAM > availableRAM ? totalRAM - availableRAM : 0 }
    var usagePercent: Double { totalRAM > 0 ? Double(usedRAM) / Double(totalRAM) : 0 }
    var fileUsagePercent: Double {
        let fileBytes = max(usedByFiles, 0)
        guard fileBytes > 0 else { return 0 }
        let referenceBytes: Double = 1_000_000_000 // 1 GB reference for scaling
        return min(Double(fileBytes) / referenceBytes, 1.0)
    }
}

// MARK: - Memory Reader

final class MemoryReader {
    static func read(fileBytes: Int64 = 0) -> MemoryInfo {
        let pageSize = UInt64(vm_kernel_page_size)
        var stats    = vm_statistics64()
        var count    = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)
        let available: UInt64
        if result == KERN_SUCCESS {
            let free     = UInt64(stats.free_count)     * pageSize
            let inactive = UInt64(stats.inactive_count) * pageSize
            available = free + inactive
        } else {
            available = total
        }
        return MemoryInfo(totalRAM: total, availableRAM: available, usedByFiles: fileBytes)
    }
}

// MARK: - Frosted Glass Background

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .withinWindow
        v.state        = .active
        v.material     = .sidebar
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Memory Status Bar

struct MemoryStatusBar: View {
    @ObservedObject var appState: AppState

    @State private var mem: MemoryInfo = MemoryReader.read()
    @State private var animateBars     = false
    @State private var ticker: Timer?

    private var fileCount:   Int   { appState.scanResult?.files.filter { !$0.isDirectory }.count ?? 0 }
    private var folderCount: Int   { appState.scanResult?.files.filter(\.isDirectory).count ?? 0 }
    private var fileBytes:   Int64 { appState.scanResult?.files.reduce(0) { $0 + ($1.fileSize ?? 0) } ?? 0 }

    private var info: MemoryInfo {
        MemoryInfo(totalRAM: mem.totalRAM, availableRAM: mem.availableRAM, usedByFiles: fileBytes)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectBlur()

            VStack(spacing: 0) {
                // hairline separator
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 0.5)

                HStack(spacing: 0) {
                    leftStats
                        .frame(maxWidth: .infinity, alignment: .leading)

                    thinDivider

                    centerBar
                        .frame(maxWidth: .infinity)

                    thinDivider

                    rightStats
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
        }
        .frame(height: 40)
        .onAppear   { triggerAnim(); startPolling() }
        .onDisappear { ticker?.invalidate() }
        .onChange(of: fileCount) { _ in triggerAnim() }
    }

    // MARK: - Left Section

    private var leftStats: some View {
        HStack(spacing: 12) {
            statPill(icon: "doc.fill",    value: "\(fileCount)",   label: "files")
            statPill(icon: "folder.fill", value: "\(folderCount)", label: "folders")

            if fileBytes > 0 {
                Text(fmt(fileBytes))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                    .foregroundStyle(Color.accentColor)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: fileBytes)
            }
        }
    }

    private func statPill(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Center Bar

    private var centerBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.10))

                    let ramW = w * CGFloat(info.usagePercent) * (animateBars ? 1 : 0)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color(nsColor: .systemIndigo).opacity(0.55),
                                     Color(nsColor: .systemBlue).opacity(0.40)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(ramW, 0))
                        .animation(.easeOut(duration: 0.9), value: animateBars)
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 5)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.10))

                    let fileW = w * CGFloat(info.fileUsagePercent) * (animateBars ? 1 : 0)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(fileW, 0))
                        .animation(.easeOut(duration: 0.9), value: animateBars)
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 5)

            HStack(spacing: 10) {
                legendChip(color: Color(nsColor: .systemBlue).opacity(0.6),
                           label: "RAM \(pct(info.usagePercent))")
                legendChip(color: .accentColor,
                           label: "Files (disk) \(pct(info.fileUsagePercent))")
            }
            .font(.system(size: 8.5))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory usage: RAM \(pct(info.usagePercent)), Files \(fmt(fileBytes)) on disk")
    }

    private func legendChip(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 10, height: 3.5)
            Text(label)
        }
    }

    // MARK: - Right Section

    private var rightStats: some View {
        HStack(spacing: 14) {
            ramStat(dot: .green,
                    value: fmt(Int64(info.availableRAM)), label: "free")
            ramStat(dot: Color(nsColor: .systemIndigo),
                    value: fmt(Int64(info.usedRAM)),      label: "used")
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(fmt(Int64(info.totalRAM)))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("total")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func ramStat(dot: Color, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dot.opacity(0.8))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Divider

    private var thinDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 0.5, height: 26)
    }

    // MARK: - Helpers

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
    private func pct(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }
    private func triggerAnim() {
        animateBars = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation { animateBars = true }
        }
    }
    private func startPolling() {
        let currentFileBytes = fileBytes
        ticker = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            let fresh = MemoryReader.read(fileBytes: currentFileBytes)
            withAnimation(.easeInOut(duration: 0.4)) { mem = fresh }
        }
        RunLoop.current.add(ticker!, forMode: .common)
    }
}