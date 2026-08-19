// The mutation door for retained history. `Terminal` stores its `LogicalLineStore` behind the
// wrapper declared here, so the only way to change the store is one of the two doors below --
// and every door pays the retained search index the maintenance the change owes it.
//
// The file boundary is the whole mechanism: Swift's `private` binds to a file, and Terminal.swift
// is ~7,800 lines, so a door declared there would be reachable from every mutation site that ever
// gets written. Declared here, it is not.
//
// Reads are not gated and cost nothing: `store` is readable directly, so the read sites in
// Terminal.swift are ordinary property accesses with no copy and no accessor.
//
// What does not belong here: search state itself. `Search` is deliberately store-free -- a second
// live reference to the store makes the arena non-uniquely referenced on every read, which is the
// copy `research/31/F13` measured -- so the doors borrow the slot instead of owning it. Eviction
// observation does not belong here either: it reads a monotone counter, so a missed observation
// only delays a reaction, and the reaction mutates viewport and selection state a store wrapper
// cannot own.

extension Terminal {
    /// Holds retained history so that a mutation which changes record ownership cannot complete
    /// without the retained search index being brought back into agreement with the store.
    ///
    /// The index stores match endpoints as record coordinates, and a record coordinate that the
    /// store no longer owns is a process trap at the next search read, not a wrong answer. Binding
    /// the search slot into the mutation signature is what makes the omission inexpressible: a
    /// caller cannot reach the store without also handing over the index that depends on it.
    struct RetainedHistory: Equatable, Sendable {
        /// Read-only outside this file. Terminal reads it directly at every one of its read sites,
        /// which is why reads pay neither a copy nor an accessor.
        private(set) var store: LogicalLineStore

        /// The one route that builds a store without an index to maintain: `Terminal.init`, where
        /// no search can exist yet.
        init(store: LogicalLineStore) {
            self.store = store
        }

        /// Mutates the store in place, then advances the retained index over what changed.
        ///
        /// One call per *logical* mutation rather than per store call: the synchronization is what
        /// costs, and a sever that makes two store calls has moved the seam once. The body gets
        /// direct `inout` access to the stored store, so no second reference exists while it
        /// writes and copy-on-write never fires.
        mutating func mutate<Result>(
            search: inout Search?,
            _ body: (inout LogicalLineStore) -> Result
        ) -> Result {
            let result = body(&store)
            guard search != nil else { return result }
            // Read the store through a short-lived copy so the synchronization does not hold a
            // store access open while it writes the index.
            let retained = store
            search?.synchronizeIndex(with: retained)
            return result
        }

        /// Replaces the whole store and re-derives the retained index against the replacement.
        ///
        /// A rebuild rather than a synchronization, because a replacement store carries a fresh
        /// identity regime: `rebased(toBudgetBytes:)` restarts record identities at one, and
        /// advancing the index over that reads as an ordinary tail regression -- which would keep
        /// retained coordinates that now name different content and retire valid ones. Re-deriving
        /// the index is the only step that lets no coordinate cross the regime boundary.
        mutating func replace(with replacement: LogicalLineStore, search: inout Search?) {
            store = replacement
            guard let current = search else { return }
            let retained = store
            search = Search(query: current.query, position: current.position, history: retained)
        }
    }
}
