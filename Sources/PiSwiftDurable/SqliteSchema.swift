import PiSwiftChord

/// The table and index names of the durable SQLite schema, all under one prefix. Migrations and runtime queries render
/// their SQL from these names, as upstream's `schema.ts` does. The unprefixed names are an immutable history: never
/// change or remove one; a rename adds a new name so historical migrations keep rendering their original objects.
internal struct SqliteSchema: Sendable, Equatable {
    struct Tables: Sendable, Equatable {
        let durableSchema, durableMetadata, recordIds, conversations, entries, tasks, submissions, documents,
            documentRevisions: String
    }
    struct Indexes: Sendable, Equatable {
        let conversationsByOwnerConversation, conversationsByOwnerTask, entriesByConversation,
            entryHeadsByConversation, tasksByStatus, tasksByConversation, tasksByKind, tasksByAbortRequested,
            tasksByBackground, submissionsByRequest, submissionsByConversation, submissionsByStatus,
            documentsByAddress, documentsByScope, documentsByScopeKind, documentRevisionsByKind: String
    }
    let tables: Tables
    let indexes: Indexes

    /// The unprefixed schema every storage used before prefixes, and still uses without one.
    static let `default` = SqliteSchema(validated: "")

    /// The schema under `prefix`, which must pass `validateSqliteSchemaPrefix(_:)`.
    init(prefix: String?) throws {
        if let prefix { try validateSqliteSchemaPrefix(prefix) }
        self.init(validated: prefix ?? "")
    }

    private init(validated prefix: String) {
        let p = prefix
        tables = Tables(
            durableSchema: p + "durable_schema", durableMetadata: p + "durable_metadata", recordIds: p + "record_ids",
            conversations: p + "conversations", entries: p + "entries", tasks: p + "tasks",
            submissions: p + "submissions", documents: p + "documents", documentRevisions: p + "document_revisions")
        indexes = Indexes(
            conversationsByOwnerConversation: p + "conversations_by_owner_conversation",
            conversationsByOwnerTask: p + "conversations_by_owner_task",
            entriesByConversation: p + "entries_by_conversation",
            entryHeadsByConversation: p + "entry_heads_by_conversation",
            tasksByStatus: p + "tasks_by_status", tasksByConversation: p + "tasks_by_conversation",
            tasksByKind: p + "tasks_by_kind", tasksByAbortRequested: p + "tasks_by_abort_requested",
            tasksByBackground: p + "tasks_by_background", submissionsByRequest: p + "submissions_by_request",
            submissionsByConversation: p + "submissions_by_conversation",
            submissionsByStatus: p + "submissions_by_status", documentsByAddress: p + "documents_by_address",
            documentsByScope: p + "documents_by_scope", documentsByScopeKind: p + "documents_by_scope_kind",
            documentRevisionsByKind: p + "document_revisions_by_kind")
    }
}

/// Options for `SqliteStorage.open(path:options:)`.
public struct SqliteStorageOptions: Sendable {
    /// Prefix for every table and index in the durable schema. It must be a SQLite identifier and must not use
    /// SQLite's reserved `sqlite_` prefix. Existing data is not migrated when this changes.
    public var prefix: String?
    /// Creates SqliteStorageOptions with the supplied values.
    public init(prefix: String? = nil) { self.prefix = prefix }
}
