// Canonical JSON-RPC method names for the DanTerm command surface.
import Foundation

public enum Methods {
    public static let hello = "hello"
    public static let ls = "ls"
    public static let tabTitle = "tab.title"
    public static let paneFocus = "pane.focus"
    public static let paneSplit = "pane.split"
    public static let newTab = "new-tab"
    public static let sendKeys = "send-keys"
    public static let themeSet = "theme.set"
    public static let todoList = "todo.list"
    public static let todoAdd = "todo.add"
    public static let todoEdit = "todo.edit"
    public static let todoDone = "todo.done"
    public static let todoOpen = "todo.open"
    public static let todoDelete = "todo.delete"
    public static let todoClearCompleted = "todo.clearCompleted"
}
