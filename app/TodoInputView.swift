/// Auto-expanding text input for the todo popover.
/// Wraps an NSTextView inside an NSScrollView with a placeholder label.
/// Starts at 1 line, grows up to 5 lines, then scrolls.
/// Self-observes text changes via notification so placeholder visibility
/// and height always stay in sync — callers just set `.string`.

import Cocoa

class TodoInputView: NSView {
    let textView: NSTextView
    private let scrollView: NSScrollView
    private let placeholderLabel: NSTextField
    private var heightConstraint: NSLayoutConstraint!
    private var textChangeObserver: Any?

    // MARK: - Height constants

    private static let inputFont = NSFont.systemFont(ofSize: 12)
    private static let inputLineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: inputFont)
    private static let inputInsetY: CGFloat = 4
    static let inputMinHeight = inputLineHeight + inputInsetY * 2
    static let inputMaxHeight = inputLineHeight * 5 + inputInsetY * 2

    // MARK: - Public API

    var string: String {
        get { textView.string }
        set {
            textView.string = newValue
            syncVisualState()
        }
    }

    // MARK: - Init

    init(placeholder: String = "Add a task…") {
        // Must use NSTextView(frame:) to get a text container/layout manager.
        textView = NSTextView(frame: .zero)
        scrollView = NSScrollView()
        placeholderLabel = NSTextField(labelWithString: placeholder)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
        textChangeObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            self?.syncVisualState()
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

        // Layout: scroll view fills this view, height controlled by constraint
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: Self.inputMinHeight)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,

            // Placeholder inset: textContainerInset.height + lineFragmentPadding
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: Self.inputInsetY + 1),
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 9),
        ])
    }

    // MARK: - Visual state sync

    /// Single authoritative method that updates both placeholder and height.
    /// Called by the string setter (programmatic) AND by the internal
    /// NSText.didChangeNotification observer (user typing).
    func syncVisualState() {
        placeholderLabel.isHidden = !textView.string.isEmpty

        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        var usedHeight = lm.usedRect(for: tc).height
        // Account for trailing newline: usedRect doesn't include the extra line fragment.
        if lm.extraLineFragmentTextContainer != nil {
            usedHeight += lm.extraLineFragmentRect.height
        }
        let total = usedHeight + Self.inputInsetY * 2
        heightConstraint.constant = max(Self.inputMinHeight, min(total, Self.inputMaxHeight))
    }
}
