// The transient list of panes the phone can attach to.
//
// It replaces the permanent pane table: choosing a pane is something the user does now and
// then, so the list costs the terminal no vertical space and appears only while the choice
// is being made.
//
// It decides nothing. It reports the row the user picked and paints the list it is given;
// the session model owns which panes exist and which one is selected.
import DanTermProtocol
import UIKit

/// Presents the pane list for as long as the user is choosing a pane.
@MainActor
final class PaneSheetViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    /// Reports the pane the user picked. The sheet dismisses itself on the way out, so a
    /// pick is one gesture and leaves the terminal on screen.
    var onSelect: ((PaneId) -> Void)?

    private let table = UITableView(frame: .zero, style: .plain)
    /// The rows the table is showing. It is the data source's copy of the projection,
    /// reloaded when the projection moves -- not a second owner of the list.
    private var panes: [PaneRosterItem]
    private var selectedPaneId: PaneId?

    /// Seeds the list from the projection, so the sheet has its rows before its first
    /// layout rather than after the next redraw.
    init(panes: [PaneRosterItem], selected: PaneId?) {
        self.panes = panes
        selectedPaneId = selected
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Paints the pane list as it stands. Called on every redraw while the sheet is up, so
    /// a pane the Mac opens or closes shows here without the user closing the sheet.
    func show(panes: [PaneRosterItem], selected: PaneId?) {
        guard self.panes != panes || selectedPaneId != selected else { return }
        self.panes = panes
        selectedPaneId = selected
        if isViewLoaded { table.reloadData() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A presented controller does not inherit the presenter's override, and the sheet
        // rises over the terminal's black, so it states the dark appearance itself.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.11, alpha: 1)
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 52
        table.register(UITableViewCell.self, forCellReuseIdentifier: "pane")
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        panes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "pane", for: indexPath)
        let pane = panes[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = pane.paneTitle
        content.secondaryText = "\(pane.groupName) / \(pane.tabTitle)"
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.accessoryType = pane.paneId == selectedPaneId ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        onSelect?(panes[indexPath.row].paneId)
        dismiss(animated: true)
    }
}
