# Portfolio 4 – NoSQL and Advanced Data Models

**Case study:** AUSRP, the same data as Portfolios 1–3, re-modelled for MongoDB 8.0.
**Models demonstrated:** **document** (students with an embedded transcript), **graph** (course prerequisites traversed with `$graphLookup`), and **key-value** (portal session tokens with TTL expiry).

```bash
./portfolio-4-nosql/run.sh     # starts a private mongod on :27117, ETL from PostgreSQL, runs the workload (~15 s)
```

| File | Purpose |
|---|---|
| [scripts/mongo_standalone.sh](scripts/mongo_standalone.sh) | start/stop a standalone `mongod` (data in `.data/`, git-ignored) |
| [scripts/etl_postgres_to_mongo.py](scripts/etl_postgres_to_mongo.py) | builds the collections from PostgreSQL and attaches the `$jsonSchema` validator |
| [scripts/mongo_workload.py](scripts/mongo_workload.py) | experiments N1–N9 |
| [results/](results/) | ETL output, sample documents, validator, workload output |

## 1. Why a NoSQL model for this case study?

The relational design (Portfolio 1) is right for the **system of record**, where registration and grading need multi-row constraints and ACID transactions. The **student-facing portal**, however, is dominated by one access pattern: *"show me everything about student X"*. That is about 20,000 students checking results many times on release day. In 3NF this needs a 7-table join (Q01). A document database can serve it as **one read of one document**.

The architecture is therefore **polyglot persistence**: PostgreSQL stays authoritative, and MongoDB is a read-optimised projection fed by an ETL/CDC pipeline (here a batch ETL; in production, logical replication or Debezium change-data-capture).

## 2. Data model

### 2.1 `students`: embedding (aggregate-oriented design)
One document per student. The transcript is **embedded** as `semesters[] → courses[]`, with pre-computed GPA/CGPA.
Sample: [results/sample_student_document.json](results/sample_student_document.json)

```json
{
  "_id": "AU/2022/00007",                       // matric number = natural key = shard key in Portfolio 5
  "student_id": 7,                               // traceability back to PostgreSQL
  "name": {"first": "Ebuka", "last": "Adeleke"},
  "programme": {"code": "B-IFT", "name": "B.Sc. Information Technology", "award": "BSc"},
  "department": {"code": "IFT", "name": "Information Technology"},   // denormalised snapshot
  "faculty": {"code": "FCI", "name": "Faculty of Computing and Informatics"},
  "level": 400, "status": "GRADUATED",
  "semesters": [
    {"session": "2022/2023", "term": "FIRST", "units": 18, "gpa": 4.44,
     "courses": [{"code": "IFT101", "title": "...", "units": 3, "ca": 16.0, "exam": 43.0,
                  "total": 59.0, "grade": "C", "gp": 3.0, "status": "COMPLETED", "result_status": "APPROVED"}, ...]},
    ...
  ],
  "summary": {"cgpa": 3.99, "units_taken": 144, "units_passed": 144, "class_of_degree": "Second Class Upper"}
}
```

**Embed or reference? The design rules I applied:**

| Data | Decision | Reason |
|---|---|---|
| results inside student | **embed** | Always read together with the student. Bounded size: at most about 60 courses, measured at **11 KB** for a graduate, far below the 16 MB document limit. Owned by one student. |
| department / programme names | **embed a copy** (extended reference) | Read on every page, and they almost never change. The cost of a rename is a multi-document update, which is accepted. |
| course title in each result | **embed a copy** | The transcript shows the title as it was *when the course was taken* (historical snapshot). |
| course catalogue | **separate collection** | Shared by thousands of students, and has its own life cycle. |
| enrollment list of a course | **not stored** | Unbounded and grows with every student. It would be an anti-pattern (an unbounded array). It is derived by aggregation when needed (N9). |

### 2.2 `courses`: polymorphic attributes and graph edges
```json
{"_id": "CSC301", "title": "...", "units": 3, "level": 300, "term": "FIRST",
 "department": {"code": "CSC", "name": "Computer Science"}, "faculty": "FCI",
 "prerequisites": ["CSC201"],                                  // graph edges (adjacency list)
 "attributes": {"lab_hours": 2, "software": ["Python","PostgreSQL"], "online_delivery": false}}
```
`attributes` has a **different shape per faculty**:
* computing: lab hours, software
* sciences: lab hours, safety training
* engineering: workshop hours, COREN accreditation
* management: case studies, professional body

In the relational model this would need either a sparse table full of NULLs or an EAV design. See [results/sample_course_documents.json](results/sample_course_documents.json).

### 2.3 `portal_sessions`: key-value pattern
`{_id: <token>, matric, role, created_at, expires_at}`, accessed only by key, with a **TTL index** on `expires_at` (`expireAfterSeconds: 0`) so the server deletes expired sessions itself.

### 2.4 Schema validation: flexible, but not schemaless
`students` has a server-side `$jsonSchema` validator ([results/students_validator.json](results/students_validator.json)). It defines:
* required fields, the matric-number pattern, and enumerations for level, status and grade;
* `ca` 0–30, `exam` 0–70, and `gpa`/`cgpa` 0–5.

These mirror the CHECK constraints of Portfolio 1.

## 3. Implementation evidence

ETL ([results/etl_output.txt](results/etl_output.txt)): **20,000 student documents** (613k results embedded) and 577 course documents, loaded in **4.5 s**.

| | PostgreSQL (Portfolio 1) | MongoDB |
|---|---|---|
| logical size of result data | 93 MB (`enrollment` heap + indexes) | 140 MB BSON (avg 7.0 KB/doc). Field names repeat in every document. |
| on disk | 109 MB (whole database) | **29.8 MB** (WiredTiger snappy compression) |

Workload output: [results/workload_output.txt](results/workload_output.txt).

| # | Experiment | Result |
|---|---|---|
| **N1** | Transcript of AU/2022/00007 | **MongoDB `find_one` by `_id`: median 0.171 ms**, compared with **PostgreSQL 7-table join: 0.349 ms** (300 runs each, client round trip). One document, 48 results, 11,054 bytes. |
| **N2** | Dean's list with `$setWindowFields` + `$denseRank` | Correct ranking (159 rows incl. ties). Before index: `COLLSCAN`, 20,000 docs examined. After `{status, department.code, summary.cgpa:-1}`: `IXSCAN`, 12,527 docs (only ACTIVE). Modest gain because a large share of the collection qualifies. |
| **N3** | Login lookup by e-mail | `COLLSCAN`, 20,000 docs, 5 ms → `EXPRESS_IXSCAN(ux_email)`, **1 doc, 1 key** |
| **N4** | Prerequisite chain of CSC412 | `$graphLookup` returns CSC312 (depth 0) → CSC212 (1) → CSC112 (2). This is **identical** to the PostgreSQL `WITH RECURSIVE` result. The reverse traversal shows that failing CSC101 transitively blocks CSC201, CSC301 and CSC401. |
| **N5** | Polymorphic attributes | Queries such as `{"attributes.software": "MongoDB", "attributes.lab_hours": {$gte: 2}}` → 64 courses. 96 courses need safety training. No schema change was needed. |
| **N6** | Post a result | One `update_one` with **arrayFilters** (`semesters.$[s].courses.$[c]`) changes CA, exam, total, grade and GP atomically: matched = 1, modified = 1. |
| **N7** | Invalid score (exam = 85) | Rejected by the server: `WriteError code 121: Document failed validation` |
| **N8** | Session store | GET by key, TTL index `expires_at_1` (0 s). The TTL monitor removes expired sessions every 60 s. |
| **N9** | Pass rate per Computing course, 2025/2026 | 192 courses in **76 ms**: each student document must be `$unwind`ed twice. PostgreSQL answers the same question (Q05) in **16 ms** from a covering index. |

## 4. Suitability: where each model fits

| Requirement | Document (MongoDB) | Relational (PostgreSQL) |
|---|---|---|
| Student portal: transcript, GPA, profile | **Best fit**: one key lookup, no joins, easy to cache and shard by matric (Portfolio 5) | 7-way join, still fast with indexes |
| Course registration (capacity, prerequisites, 24-unit limit across rows) | Weak: the rules span documents, so it needs multi-document transactions and loses the main benefit | **Best fit**: constraints, row locks, SERIALIZABLE (Portfolio 3) |
| Result entry by a lecturer for a whole course | Awkward: the course's students are spread over hundreds of documents | **Best fit**: one `UPDATE … WHERE offering_id = ?` |
| Ad-hoc analytics (pass rates, Senate reports) | Possible with aggregation, but slower (N9) | **Best fit**: set-based SQL, covering indexes |
| Heterogeneous course attributes | **Best fit**: natural sub-documents | JSONB column or EAV |
| Prerequisite graph | `$graphLookup` is adequate at this size. A native graph DB (Neo4j) would suit large, deep graphs. | `WITH RECURSIVE` is adequate |
| Session / cache data with expiry | **Good**: TTL index. Redis would be the specialised key-value choice. | Needs a cron job to purge |

**Conclusion:** model around the **access patterns**. AUSRP keeps PostgreSQL as the transactional source of truth and uses MongoDB as a **read model** for the student portal (CQRS style). The trade-offs are:
* **Eventual consistency between the two stores**: a newly approved result appears in the portal after the next sync.
* **Duplicated data** (department names, course titles) that must be refreshed by the pipeline.

Both are acceptable because published results change rarely and only through a controlled approval process.
