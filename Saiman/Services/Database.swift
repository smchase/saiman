import Foundation
import SQLite3

final class Database {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.saiman.database", qos: .userInitiated)

    private init() {
        setupDatabase()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Setup

    private func setupDatabase() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let saimanDir = appSupport.appendingPathComponent("Saiman", isDirectory: true)

        try? fileManager.createDirectory(at: saimanDir, withIntermediateDirectories: true)

        let dbPath = saimanDir.appendingPathComponent("saiman.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Error opening database: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        createTables()
    }

    private func createTables() {
        let createConversations = """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """

        let createMessages = """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                tool_calls TEXT,
                attachments TEXT,
                created_at REAL NOT NULL,
                FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            );
            """

        let createIndex = """
            CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id);
            """

        // FTS for search
        let createFTS = """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                content,
                content=messages,
                content_rowid=rowid
            );
            """

        let triggers = """
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.rowid, old.content);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content);
            END;
            """

        execute(createConversations)
        execute(createMessages)
        execute(createIndex)
        execute(createFTS)
        execute(triggers)

        // Migration: add attachments column if it doesn't exist
        migrateAddAttachmentsColumn()

        // Migration: add tool_usage_summary column if it doesn't exist
        migrateAddToolUsageSummaryColumn()
    }

    private func migrateAddAttachmentsColumn() {
        // Check if column exists by trying to query it
        let checkSql = "SELECT attachments FROM messages LIMIT 1;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, checkSql, -1, &stmt, nil) != SQLITE_OK {
            // Column doesn't exist, add it
            execute("ALTER TABLE messages ADD COLUMN attachments TEXT;")
            Logger.shared.info("Database migrated: added attachments column")
        }
        sqlite3_finalize(stmt)
    }

    private func migrateAddToolUsageSummaryColumn() {
        // Check if column exists by trying to query it
        let checkSql = "SELECT tool_usage_summary FROM messages LIMIT 1;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, checkSql, -1, &stmt, nil) != SQLITE_OK {
            // Column doesn't exist, add it
            execute("ALTER TABLE messages ADD COLUMN tool_usage_summary TEXT;")
            Logger.shared.info("Database migrated: added tool_usage_summary column")
        }
        sqlite3_finalize(stmt)
    }

    private func execute(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("SQL error: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    // MARK: - Conversations

    func createConversation(_ conversation: Conversation) {
        queue.sync {
            let sql = "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, ?, ?, ?);"
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, conversation.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, conversation.title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_double(stmt, 3, conversation.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 4, conversation.updatedAt.timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func updateConversation(_ conversation: Conversation) {
        queue.sync {
            let sql = "UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, conversation.title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_double(stmt, 2, conversation.updatedAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, conversation.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func getConversation(id: UUID) -> Conversation? {
        queue.sync {
            let sql = "SELECT id, title, created_at, updated_at FROM conversations WHERE id = ?;"
            var stmt: OpaquePointer?
            var conversation: Conversation?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

                if sqlite3_step(stmt) == SQLITE_ROW {
                    conversation = conversationFromStatement(stmt)
                }
            }
            sqlite3_finalize(stmt)
            return conversation
        }
    }

    func getMostRecentConversation() -> Conversation? {
        queue.sync {
            let sql = "SELECT id, title, created_at, updated_at FROM conversations ORDER BY updated_at DESC LIMIT 1;"
            var stmt: OpaquePointer?
            var conversation: Conversation?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    conversation = conversationFromStatement(stmt)
                }
            }
            sqlite3_finalize(stmt)
            return conversation
        }
    }

    func getAllConversations() -> [Conversation] {
        queue.sync {
            let sql = "SELECT id, title, created_at, updated_at FROM conversations ORDER BY updated_at DESC LIMIT 20;"
            var stmt: OpaquePointer?
            var conversations: [Conversation] = []

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let conversation = conversationFromStatement(stmt) {
                        conversations.append(conversation)
                    }
                }
            }
            sqlite3_finalize(stmt)
            return conversations
        }
    }

    func searchConversations(query: String) -> [Conversation] {
        queue.sync {
            // Case-insensitive substring search on titles and message content
            let pattern = "%\(query)%"
            let sql = """
                SELECT DISTINCT c.id, c.title, c.created_at, c.updated_at
                FROM conversations c
                LEFT JOIN messages m ON c.id = m.conversation_id
                WHERE LOWER(c.title) LIKE LOWER(?)
                   OR (LOWER(m.content) LIKE LOWER(?) AND m.role IN ('user', 'assistant'))
                ORDER BY c.updated_at DESC
                LIMIT 20;
                """
            var stmt: OpaquePointer?
            var conversations: [Conversation] = []

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let conversation = conversationFromStatement(stmt) {
                        conversations.append(conversation)
                    }
                }
            }
            sqlite3_finalize(stmt)
            return conversations
        }
    }

    func deleteConversation(id: UUID) {
        queue.sync {
            // Messages will be deleted via CASCADE
            let sql = "DELETE FROM conversations WHERE id = ?;"
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func deleteMessage(id: UUID) {
        queue.sync {
            let sql = "DELETE FROM messages WHERE id = ?;"
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    private func conversationFromStatement(_ stmt: OpaquePointer?) -> Conversation? {
        guard let idStr = sqlite3_column_text(stmt, 0),
              let titleStr = sqlite3_column_text(stmt, 1),
              let id = UUID(uuidString: String(cString: idStr)) else {
            return nil
        }

        return Conversation(
            id: id,
            title: String(cString: titleStr),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        )
    }

    // MARK: - Messages

    func createMessage(_ message: Message) {
        queue.sync {
            let sql = "INSERT INTO messages (id, conversation_id, role, content, tool_calls, attachments, tool_usage_summary, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, message.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, message.conversationId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 3, message.role.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 4, message.content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

                if let toolCalls = message.toolCalls,
                   let toolCallsData = try? JSONEncoder().encode(toolCalls),
                   let toolCallsString = String(data: toolCallsData, encoding: .utf8) {
                    sqlite3_bind_text(stmt, 5, toolCallsString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                } else {
                    sqlite3_bind_null(stmt, 5)
                }

                if let attachments = message.attachments,
                   let attachmentsData = try? JSONEncoder().encode(attachments),
                   let attachmentsString = String(data: attachmentsData, encoding: .utf8) {
                    sqlite3_bind_text(stmt, 6, attachmentsString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                } else {
                    sqlite3_bind_null(stmt, 6)
                }

                if let summary = message.toolUsageSummary {
                    sqlite3_bind_text(stmt, 7, summary, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                } else {
                    sqlite3_bind_null(stmt, 7)
                }

                sqlite3_bind_double(stmt, 8, message.createdAt.timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func getMessages(conversationId: UUID) -> [Message] {
        queue.sync {
            let sql = "SELECT id, conversation_id, role, content, tool_calls, attachments, tool_usage_summary, created_at FROM messages WHERE conversation_id = ? ORDER BY created_at ASC;"
            var stmt: OpaquePointer?
            var messages: [Message] = []

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, conversationId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let message = messageFromStatement(stmt) {
                        messages.append(message)
                    }
                }
            }
            sqlite3_finalize(stmt)
            return messages
        }
    }

    func getLastMessage(conversationId: UUID) -> Message? {
        queue.sync {
            let sql = "SELECT id, conversation_id, role, content, tool_calls, attachments, tool_usage_summary, created_at FROM messages WHERE conversation_id = ? ORDER BY created_at DESC LIMIT 1;"
            var stmt: OpaquePointer?
            var message: Message?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, conversationId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

                if sqlite3_step(stmt) == SQLITE_ROW {
                    message = messageFromStatement(stmt)
                }
            }
            sqlite3_finalize(stmt)
            return message
        }
    }

    private func messageFromStatement(_ stmt: OpaquePointer?) -> Message? {
        guard let idStr = sqlite3_column_text(stmt, 0),
              let convIdStr = sqlite3_column_text(stmt, 1),
              let roleStr = sqlite3_column_text(stmt, 2),
              let contentStr = sqlite3_column_text(stmt, 3),
              let id = UUID(uuidString: String(cString: idStr)),
              let convId = UUID(uuidString: String(cString: convIdStr)),
              let role = MessageRole(rawValue: String(cString: roleStr)) else {
            return nil
        }

        var toolCalls: [ToolCall]?
        if let toolCallsStr = sqlite3_column_text(stmt, 4) {
            let toolCallsData = Data(String(cString: toolCallsStr).utf8)
            toolCalls = try? JSONDecoder().decode([ToolCall].self, from: toolCallsData)
        }

        var attachments: [Attachment]?
        if let attachmentsStr = sqlite3_column_text(stmt, 5) {
            let attachmentsData = Data(String(cString: attachmentsStr).utf8)
            attachments = try? JSONDecoder().decode([Attachment].self, from: attachmentsData)
        }

        var toolUsageSummary: String?
        if let summaryStr = sqlite3_column_text(stmt, 6) {
            toolUsageSummary = String(cString: summaryStr)
        }

        return Message(
            id: id,
            conversationId: convId,
            role: role,
            content: String(cString: contentStr),
            toolCalls: toolCalls,
            attachments: attachments,
            toolUsageSummary: toolUsageSummary,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        )
    }
}
