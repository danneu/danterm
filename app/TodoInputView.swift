/// Fixed-height text input for the todo popover.
/// Wraps an NSTextView inside an NSScrollView with a placeholder label.
/// The visible line count is configurable; scrolls when content overflows.
/// Self-observes text changes via notification to keep placeholder in sync.

import Cocoa

/// NSScrollView subclass that draws the system focus ring when its
/// document view (NSTextView) is the first responder. Standard NSScrollView
/// doesn't do this automatically — only NSControl subclasses get it for free.
private class FocusRingScrollView: NSScrollView {
    override var needsPanelToBecomeKey: Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    /// Redraw the focus ring when focus enters or leaves the text view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusRingType = .exterior
    }
}

class TodoInputView: NSView {
    let textView: NSTextView
    private let scrollView: FocusRingScrollView
    private let placeholderLabel: NSTextField
    private var textChangeObserver: Any?
    private let visibleLineCount: Int

    // MARK: - Height constants

    static let defaultVisibleLineCount = 3
    static let editVisibleLineCount = 8
    static let inputFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let inputLineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: inputFont)
    static let inputInsetY: CGFloat = 4
    static let inputHeight = height(visibleLineCount: defaultVisibleLineCount)

    static func height(visibleLineCount: Int) -> CGFloat {
        inputLineHeight * CGFloat(visibleLineCount) + inputInsetY * 2
    }

    // MARK: - Public API

    var string: String {
        get { textView.string }
        set {
            textView.string = newValue
            updatePlaceholder()
        }
    }

    // MARK: - Init

    init(placeholder: String = "Add a task…", visibleLineCount: Int = defaultVisibleLineCount) {
        // Must use NSTextView(frame:) to get a text container/layout manager.
        textView = NSTextView(frame: .zero)
        scrollView = FocusRingScrollView()
        placeholderLabel = NSTextField(labelWithString: placeholder)
        self.visibleLineCount = visibleLineCount
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
        textChangeObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            self?.updatePlaceholder()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let observer = textChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupViews() {
        // Text view
        textView.font = Self.inputFont
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: 4, height: Self.inputInsetY)
        textView.textContainer?.lineFragmentPadding = 5
        textView.drawsBackground = false
        textView.insertionPointColor = .labelColor

        // Scroll view
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Placeholder (floats above the text view, inside the scroll view)
        placeholderLabel.font = Self.inputFont
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.height(visibleLineCount: visibleLineCount)),

            // Placeholder inset: textContainerInset.height + lineFragmentPadding
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: Self.inputInsetY + 1),
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 9),
        ])
    }

    // MARK: - Placeholder

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }
}
