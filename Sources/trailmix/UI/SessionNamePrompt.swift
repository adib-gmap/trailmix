import AppKit
import UniformTypeIdentifiers

/// The window shown when a recording starts, before the screen chooser:
/// "Video used for training?" Yes gives Role, Objective, Step and Description
/// and files the recording in the SOP library's drafts folder; No takes one
/// line of description and files it under the recordings root. The right
/// column lists the library as it is on disk, and clicking a folder there
/// fills the fields, so a second part of a step is two clicks.
///
/// Same shape as `DisplayPicker`: one at a time, awaited through a
/// continuation, dismissed by Cancel, Esc, the close box, or the start/stop
/// shortcut pressed again. Nil means cancelled and nothing is recorded. The
/// window is gone before the folder is created, so a cancel leaves no trace.
@MainActor
final class SessionNamePrompt: NSObject {
    private static var active: SessionNamePrompt?

    private let root: URL
    private let layout: SessionNaming.Layout
    private var library: SOPNode?
    private var continuation: CheckedContinuation<SessionNaming.Request?, Never>?
    private var previousApp: NSRunningApplication?

    private let window: NSWindow
    private let yesButton = NSButton(radioButtonWithTitle: "Yes", target: nil, action: nil)
    private let noButton = NSButton(radioButtonWithTitle: "No", target: nil, action: nil)
    private let roleBox = NSComboBox()
    private let objectiveBox = NSComboBox()
    private let stepField = NSTextField()
    private let descriptionField = NSTextField()
    private let quickField = NSTextField()
    private let trainingForm: NSGridView
    private let quickForm: NSGridView
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "Start recording", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let outline = NSOutlineView()
    private let treeScroll = NSScrollView()
    private let treePlaceholder = NSTextField(wrappingLabelWithString: "")

    /// Show the prompt and wait for an answer. Nil means cancelled.
    static func ask(root: URL, layout: SessionNaming.Layout) async -> SessionNaming.Request? {
        active?.finish(with: nil)
        let prompt = SessionNamePrompt(root: root, layout: layout)
        active = prompt
        return await withCheckedContinuation { continuation in
            prompt.continuation = continuation
            prompt.show()
        }
    }

    /// Dismiss a prompt that is up, if any. True when there was one: the
    /// caller then knows the click or shortcut it is handling was a cancel.
    @discardableResult
    static func cancelActive() -> Bool {
        guard let prompt = active else { return false }
        prompt.finish(with: nil)
        return true
    }

    private init(root: URL, layout: SessionNaming.Layout) {
        self.root = root
        self.layout = layout
        trainingForm = Self.grid(rows: [
            ("Role", roleBox), ("Objective", objectiveBox),
            ("Step", stepField), ("Description", descriptionField),
        ])
        quickForm = Self.grid(rows: [("Description", quickField)])
        // A titled, activating window: typing has to reach the fields, and a
        // non-activating panel would leave the keystrokes with whatever app
        // was in front. `.floating` keeps it above that app; the collection
        // behaviour lets it show over a full-screen Meet.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Trailmix"
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContent()
        window.contentMinSize = Self.baseSize
    }

    private static let baseSize = NSSize(width: 820, height: 460)
    /// Window chrome outside the folder list: margins, the 360-wide form, the
    /// gap between the columns.
    private static let besideTree: CGFloat = 20 + 360 + 20 + 20

    /// Widen the window so the longest folder name in the library shows in
    /// full, up to the width of the screen it opens on. Recomputed on every
    /// show because the library grows; never narrower than the base size.
    private func fitWidthToLibrary() {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.width ?? Self.baseSize.width
        let tree = library.map { Self.widestRow($0, depth: 0) } ?? 0
        // Scroller, bezel border, and a little air after the last letter.
        let wanted = Self.besideTree + tree + 15 + 4 + 12
        let width = min(max(Self.baseSize.width, ceil(wanted)), screen - 40)
        let height = window.contentRect(forFrameRect: window.frame).height
        window.setContentSize(NSSize(width: width, height: max(height, Self.baseSize.height)))
    }

    /// The width a row and its descendants need: indentation and disclosure
    /// triangle, the 16 pt icon with its padding (see `makeCell`), and the
    /// name in the font `viewFor` gives it.
    private static func widestRow(_ node: SOPNode, depth: Int) -> CGFloat {
        let heading = node.kind == .drafts || node.kind == .sopRoot
        let font = heading ? NSFont.systemFont(ofSize: 12, weight: .semibold) : NSFont.systemFont(ofSize: 12)
        let text = (node.name as NSString).size(withAttributes: [.font: font]).width
        let own = CGFloat(depth) * 14 + 20 + 2 + 16 + 4 + text + 2 + 6
        return node.children.reduce(own) { max($0, widestRow($1, depth: depth + 1)) }
    }

    // MARK: - Showing and finishing

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        library = SOPTree.read(root: root, layout: layout)
        reloadTree()
        fitWidthToLibrary()
        reloadCompletions()
        yesButton.state = .on
        noButton.state = .off
        answerChanged(yesButton)

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(roleBox)
    }

    private func finish(with request: SessionNaming.Request?) {
        guard let continuation else { return }
        self.continuation = nil
        window.orderOut(nil)
        if Self.active === self { Self.active = nil }
        if let previousApp, previousApp != .current {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        continuation.resume(returning: request)
    }

    @objc private func startClicked(_ sender: Any?) {
        // Commit the field editor first: a combo box mid-completion reports
        // the completed text only once editing ends.
        window.makeFirstResponder(nil)
        let request = currentRequest()
        if isTraining, SessionNaming.folder(for: request, layout: layout, date: Date()) == nil {
            refreshPreview()
            window.makeFirstResponder(roleBox.stringValue.isEmpty ? roleBox : objectiveBox)
            return
        }
        finish(with: request)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        finish(with: nil)
    }

    // MARK: - Form state

    private var isTraining: Bool { yesButton.state == .on }

    private func currentRequest() -> SessionNaming.Request {
        if isTraining {
            return .training(
                role: roleBox.stringValue,
                objective: objectiveBox.stringValue,
                step: stepField.stringValue,
                description: descriptionField.stringValue
            )
        }
        return .quick(description: quickField.stringValue)
    }

    @objc private func answerChanged(_ sender: Any?) {
        trainingForm.isHidden = !isTraining
        quickForm.isHidden = isTraining
        refreshPreview()
        window.makeFirstResponder(isTraining ? roleBox : quickField)
    }

    /// The folder the current answers would create, shown under the form so
    /// nobody has to guess, and the Start button's enabled state.
    private func refreshPreview() {
        let request = currentRequest()
        if let folder = SessionNaming.folder(for: request, layout: layout, date: Date()) {
            preview.stringValue = "Saves to: \(folder.relativePath)"
            preview.textColor = .secondaryLabelColor
            startButton.isEnabled = true
        } else if isTraining {
            preview.stringValue = "Role, Objective and a Step or Description are needed."
            preview.textColor = .systemOrange
            startButton.isEnabled = false
        } else {
            preview.stringValue = "Saves to: \(SessionNaming.timestamp(Date())) (no description)"
            preview.textColor = .secondaryLabelColor
            startButton.isEnabled = true
        }
    }

    private func reloadCompletions() {
        roleBox.removeAllItems()
        objectiveBox.removeAllItems()
        guard let library else { return }
        roleBox.addItems(withObjectValues: SOPTree.roles(in: library))
        objectiveBox.addItems(withObjectValues: SOPTree.objectives(in: library, forRole: roleBox.stringValue))
    }

    private func reloadObjectives() {
        guard let library else { return }
        objectiveBox.removeAllItems()
        objectiveBox.addItems(withObjectValues: SOPTree.objectives(in: library, forRole: roleBox.stringValue))
    }

    private func reloadTree() {
        let empty = library == nil
        treeScroll.isHidden = empty
        treePlaceholder.isHidden = !empty
        treePlaceholder.stringValue =
            "No SOP folders yet. The first training recording creates\n"
            + "\(layout.effective.sopRoot)/\(layout.effective.drafts)/ in the recordings folder."
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let content = NSView()

        for button in [yesButton, noButton] {
            button.target = self
            button.action = #selector(answerChanged(_:))
        }
        let question = NSTextField(labelWithString: "Video used for training?")
        question.font = .boldSystemFont(ofSize: 13)
        let radios = NSStackView(views: [yesButton, noButton])
        radios.orientation = .horizontal
        radios.spacing = 16

        for field in [stepField, descriptionField, quickField] {
            field.delegate = self
            field.cell?.sendsActionOnEndEditing = true
        }
        for box in [roleBox, objectiveBox] {
            box.delegate = self
            box.completes = true
            box.numberOfVisibleItems = 10
        }
        stepField.placeholderString = "e.g. Intake"
        descriptionField.placeholderString = "e.g. pt1"
        quickField.placeholderString = "e.g. Precon meeting (empty = timestamp)"

        preview.font = .systemFont(ofSize: 11)
        preview.textColor = .secondaryLabelColor
        preview.preferredMaxLayoutWidth = 360

        let left = NSStackView(views: [question, radios, trainingForm, quickForm, preview])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 12
        left.translatesAutoresizingMaskIntoConstraints = false
        for view in [trainingForm, quickForm, preview] {
            view.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 20
        outline.indentationPerLevel = 14
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true
        treeScroll.borderType = .bezelBorder
        treeScroll.translatesAutoresizingMaskIntoConstraints = false

        treePlaceholder.font = .systemFont(ofSize: 11)
        treePlaceholder.textColor = .secondaryLabelColor
        treePlaceholder.preferredMaxLayoutWidth = 380
        let treeTitle = NSTextField(labelWithString: "SOP library (click a folder to fill the fields)")
        treeTitle.font = .systemFont(ofSize: 11, weight: .medium)
        treeTitle.textColor = .secondaryLabelColor
        let right = NSStackView(views: [treeTitle, treeScroll, treePlaceholder])
        right.orientation = .vertical
        right.alignment = .leading
        right.distribution = .fill
        right.spacing = 6
        treeScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        right.translatesAutoresizingMaskIntoConstraints = false
        treeScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        treePlaceholder.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        // .fill, not the default gravity areas: the form keeps its fixed 360
        // and the folder list takes every point the window is widened by
        // (`fitWidthToLibrary`, or a drag). With gravity areas the window
        // grew and the list stayed put, leaving an empty strip.
        columns.distribution = .fill
        columns.spacing = 20
        left.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentHuggingPriority(.defaultLow, for: .horizontal)
        treeScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // An NSGridView has no intrinsic height, so nothing stopped the form
        // being stretched to the height of the list, and the grid handed the
        // extra to its first row: a tall gap under Role. This pulls the form
        // down to the height its rows need, below every content priority.
        let tight = left.heightAnchor.constraint(equalToConstant: 0)
        tight.priority = NSLayoutConstraint.Priority(300)
        tight.isActive = true
        columns.translatesAutoresizingMaskIntoConstraints = false

        startButton.target = self
        startButton.action = #selector(startClicked(_:))
        startButton.keyEquivalent = "\r"
        startButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancelButton, startButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(columns)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            columns.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            columns.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            columns.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            left.widthAnchor.constraint(equalToConstant: 360),
            right.heightAnchor.constraint(equalTo: columns.heightAnchor),
            treeScroll.bottomAnchor.constraint(lessThanOrEqualTo: right.bottomAnchor),
            treeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        return content
    }

    private static func grid(rows: [(String, NSView)]) -> NSGridView {
        var views: [[NSView]] = []
        for (title, field) in rows {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            views.append([label, field])
        }
        let grid = NSGridView(views: views)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 80
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let sessionIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "recording")
        return image?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }()
}

// MARK: - Window

extension SessionNamePrompt: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(with: nil)
        return false
    }
}

// MARK: - Fields

extension SessionNamePrompt: NSComboBoxDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSComboBox) === roleBox { reloadObjectives() }
        refreshPreview()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The box's stringValue is still the old text while this fires; the
        // selected item is what it is about to become.
        guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
              let value = box.itemObjectValue(at: box.indexOfSelectedItem) as? String
        else { return }
        if box === roleBox {
            roleBox.stringValue = value
            reloadObjectives()
        } else if box === objectiveBox {
            objectiveBox.stringValue = value
        }
        refreshPreview()
    }
}

// MARK: - Tree

extension SessionNamePrompt: NSOutlineViewDataSource, NSOutlineViewDelegate {
    private func node(_ item: Any?) -> SOPNode? {
        item == nil ? library : item as? SOPNode
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return library == nil ? 0 : 1 }
        return node(item)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let parent = node(item) else { return NSNull() }
        return item == nil ? parent : parent.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !(node(item)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = node(item) else { return nil }
        let id = NSUserInterfaceItemIdentifier("node")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? Self.makeCell(id)
        cell.textField?.stringValue = node.name
        // The full name on hover, for a name longer than even the widened
        // window (a narrow screen caps it).
        cell.toolTip = node.name
        cell.imageView?.image = node.kind == .session ? Self.sessionIcon : Self.folderIcon
        let heading = node.kind == .drafts || node.kind == .sopRoot
        cell.textField?.font = heading ? NSFont.systemFont(ofSize: 12, weight: .semibold) : NSFont.systemFont(ofSize: 12)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SOPNode else { return }
        switch node.kind {
        case .roleObjective:
            fill(roleObjective: node.name)
        case .session:
            if let parent = outline.parent(forItem: node) as? SOPNode {
                fill(roleObjective: parent.name)
            }
            if let parsed = SessionNaming.parseSession(node.name) {
                stepField.stringValue = parsed.step
            }
        default:
            return
        }
        if !isTraining {
            yesButton.state = .on
            noButton.state = .off
            answerChanged(yesButton)
        }
        refreshPreview()
        window.makeFirstResponder(node.kind == .session ? descriptionField : stepField)
    }

    private func fill(roleObjective name: String) {
        let parsed = SessionNaming.parseRoleObjective(name)
        roleBox.stringValue = parsed.role
        reloadObjectives()
        objectiveBox.stringValue = parsed.objective
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
