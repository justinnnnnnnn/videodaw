import Foundation

/// The current project plus undo and redo stacks of whole-project snapshots.
public struct History: Equatable, Sendable {
    /// The most undo steps kept; older ones are dropped.
    public static let limit = 500

    public private(set) var project: Project
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var coalescingKey: String?

    public init(_ project: Project = Project()) { self.project = project }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Applies an edit as one undo step and returns whatever the edit returns. An edit that
    /// leaves the project unchanged records nothing and keeps the redo stack.
    @discardableResult
    public mutating func perform<T>(_ edit: (inout Project) -> T) -> T {
        endCoalescing()
        return apply(edit, coalescingKey: nil)
    }

    /// Like `perform`, but consecutive calls with the same key (one mouse drag, say) share a
    /// single undo step. The group ends at `endCoalescing`, a different key, a plain
    /// `perform`, or an undo or redo.
    @discardableResult
    public mutating func performCoalescing<T>(key: String, _ edit: (inout Project) -> T) -> T {
        if coalescingKey != key { endCoalescing() }
        return apply(edit, coalescingKey: key)
    }

    /// Closes the open coalescing group. A group that ended where it began leaves no undo step.
    public mutating func endCoalescing() {
        guard coalescingKey != nil else { return }
        coalescingKey = nil
        if undoStack.last == project { undoStack.removeLast() }
    }

    /// Changes the current project without recording an undo step, for bookkeeping that is
    /// not a user edit (capturing plugin state, noting a finished proxy).
    public mutating func amend(_ edit: (inout Project) -> Void) {
        edit(&project)
    }

    @discardableResult
    public mutating func undo() -> Bool {
        endCoalescing()
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(project)
        project = previous
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        endCoalescing()
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(project)
        project = next
        return true
    }

    private mutating func apply<T>(_ edit: (inout Project) -> T, coalescingKey key: String?) -> T {
        var edited = project
        let result = edit(&edited)
        guard edited != project else { return result }
        if key == nil || coalescingKey != key {
            undoStack.append(project)
            if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
            coalescingKey = key
        }
        project = edited
        redoStack.removeAll()
        return result
    }
}
