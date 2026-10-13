// Shows the progress of pr-downloader in a window. Reads its output from stdin,
// passes it through to stdout and exits on EOF. The window only opens for
// downloads large enough to take a while.

import AppKit

let minVisibleSize: Int64 = 20_000_000

final class ProgressWindow: NSObject, NSApplicationDelegate {
	let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
	                      styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
	let title = NSTextField(labelWithString: "Lade Spieldaten herunter...")
	let detail = NSTextField(labelWithString: "")
	let bar = NSProgressIndicator()
	var name = ""

	func applicationDidFinishLaunching(_ notification: Notification) {
		window.title = "Beyond All Reason"
		bar.isIndeterminate = false
		bar.minValue = 0
		bar.maxValue = 1
		detail.textColor = .secondaryLabelColor
		detail.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

		let stack = NSStackView(views: [title, bar, detail])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
		bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
		window.contentView = stack
		window.center()

		Thread.detachNewThread { self.readInput() }
	}

	func readInput() {
		let stdin = FileHandle.standardInput
		var pending = Data()
		while true {
			let chunk = stdin.availableData
			if chunk.isEmpty {
				break
			}
			FileHandle.standardOutput.write(chunk)
			pending.append(chunk)
			while let end = pending.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
				let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
				pending.removeSubrange(pending.startIndex...end)
				DispatchQueue.main.async { self.handle(line) }
			}
		}
		DispatchQueue.main.async { NSApp.terminate(nil) }
	}

	func handle(_ line: String) {
		if let range = line.range(of: "[Download] ") {
			name = String(line[range.upperBound...])
			title.stringValue = "Lade \(name) herunter..."
			return
		}
		guard line.hasPrefix("[Progress]"), let counts = line.split(separator: " ").last?.split(separator: "/"),
		      counts.count == 2, let done = Int64(counts[0]), let total = Int64(counts[1]), total > 0 else {
			return
		}
		if !window.isVisible {
			guard total >= minVisibleSize else {
				return
			}
			NSApp.setActivationPolicy(.regular)
			window.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
		}
		bar.doubleValue = Double(done) / Double(total)
		let format = ByteCountFormatter()
		detail.stringValue = "\(format.string(fromByteCount: done)) von \(format.string(fromByteCount: total))"
	}
}

let app = NSApplication.shared
let delegate = ProgressWindow()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
