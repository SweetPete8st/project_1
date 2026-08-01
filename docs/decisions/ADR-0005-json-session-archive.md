# ADR-0005: JSON session archive at v1; SwiftData deferred

**Status:** accepted · **Deviates from:** 05 §2 (SwiftData entities)

Session outcomes persist as one JSON document per session (`SessionArchive`) plus the
binary chunk files. Rationale: the archive is readable, testable, and identical on Linux
(engine recovery tests run in CI), sessions are write-once documents with no cross-entity
queries at v1 scale, and export (FR-55) is nearly free. SwiftData lands when query needs
appear (History calendar heat / DailyAggregates at scale, Spots relations — post-M4);
`SessionRecord` is already the migration source of truth. The 05 §2 schema remains the
target shape.
