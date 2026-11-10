-- AUSRP schema

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
CREATE TABLE faculty (
    faculty_id      SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            VARCHAR(10)  NOT NULL UNIQUE,
    name            VARCHAR(120) NOT NULL UNIQUE
);

CREATE TABLE department (
    department_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    faculty_id      SMALLINT     NOT NULL REFERENCES faculty(faculty_id) ON DELETE RESTRICT,
    code            CHAR(3)      NOT NULL UNIQUE CHECK (code ~ '^[A-Z]{3}$'),
    name            VARCHAR(120) NOT NULL UNIQUE
);

CREATE TABLE programme (
    programme_id    SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    department_id   SMALLINT     NOT NULL REFERENCES department(department_id) ON DELETE RESTRICT,
    code            VARCHAR(12)  NOT NULL UNIQUE,
    name            VARCHAR(150) NOT NULL,
    award           VARCHAR(10)  NOT NULL CHECK (award IN ('BSc','BEng','BA','MSc','MIT','PGD')),
    duration_years  SMALLINT     NOT NULL CHECK (duration_years BETWEEN 1 AND 6),
    UNIQUE (department_id, name)
);

CREATE TABLE lecturer (
    lecturer_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staff_no        VARCHAR(12)  NOT NULL UNIQUE CHECK (staff_no ~ '^SP/[0-9]{5}$'),
    department_id   SMALLINT     NOT NULL REFERENCES department(department_id),
    title           VARCHAR(10)  NOT NULL CHECK (title IN ('Mr','Mrs','Ms','Dr','Prof')),
    first_name      VARCHAR(60)  NOT NULL,
    last_name       VARCHAR(60)  NOT NULL,
    email           VARCHAR(120) NOT NULL UNIQUE CHECK (email ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'),
    academic_rank   VARCHAR(30)  NOT NULL CHECK (academic_rank IN
                       ('Assistant Lecturer','Lecturer II','Lecturer I',
                        'Senior Lecturer','Associate Professor','Professor')),
    hire_date       DATE         NOT NULL
);
CREATE TABLE student (
    student_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    matric_no       VARCHAR(15)  NOT NULL UNIQUE CHECK (matric_no ~ '^AU/[0-9]{4}/[0-9]{5}$'),
    programme_id    SMALLINT     NOT NULL REFERENCES programme(programme_id),
    first_name      VARCHAR(60)  NOT NULL,
    last_name       VARCHAR(60)  NOT NULL,
    gender          CHAR(1)      NOT NULL CHECK (gender IN ('M','F')),
    date_of_birth   DATE         NOT NULL,
    email           VARCHAR(120) NOT NULL UNIQUE CHECK (email ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'),
    entry_year      SMALLINT     NOT NULL CHECK (entry_year BETWEEN 2000 AND 2100),
    current_level   SMALLINT     NOT NULL CHECK (current_level IN (100,200,300,400,500,600)),
    status          VARCHAR(12)  NOT NULL DEFAULT 'ACTIVE'
                       CHECK (status IN ('ACTIVE','PROBATION','GRADUATED','WITHDRAWN','SUSPENDED')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (date_of_birth < make_date(entry_year - 14, 1, 1))
);
CREATE TABLE course (
    course_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_code     CHAR(6)      NOT NULL UNIQUE CHECK (course_code ~ '^[A-Z]{3}[1-6][0-9]{2}$'),
    title           VARCHAR(150) NOT NULL,
    department_id   SMALLINT     NOT NULL REFERENCES department(department_id),
    credit_units    SMALLINT     NOT NULL CHECK (credit_units BETWEEN 1 AND 6),
    level           SMALLINT     NOT NULL CHECK (level IN (100,200,300,400,500,600)),
    term            VARCHAR(6)   NOT NULL CHECK (term IN ('FIRST','SECOND')),
    -- CSC3xx must be a 300-level course
    CHECK (substr(course_code, 4, 1)::int * 100 = level)
);

CREATE TABLE course_prerequisite (
    course_id         INTEGER NOT NULL REFERENCES course(course_id) ON DELETE CASCADE,
    prereq_course_id  INTEGER NOT NULL REFERENCES course(course_id) ON DELETE CASCADE,
    PRIMARY KEY (course_id, prereq_course_id),
    CHECK (course_id <> prereq_course_id)
);
CREATE TABLE academic_session (
    session_id      SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            CHAR(9) NOT NULL UNIQUE CHECK (name ~ '^[0-9]{4}/[0-9]{4}$'
                        AND substr(name,6,4)::int = substr(name,1,4)::int + 1),
    start_date      DATE NOT NULL,
    end_date        DATE NOT NULL,
    CHECK (end_date > start_date)
);

CREATE TABLE semester (
    semester_id        SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id         SMALLINT   NOT NULL REFERENCES academic_session(session_id),
    term               VARCHAR(6) NOT NULL CHECK (term IN ('FIRST','SECOND')),
    start_date         DATE       NOT NULL,
    end_date           DATE       NOT NULL,
    registration_open  BOOLEAN    NOT NULL DEFAULT FALSE,
    results_published  BOOLEAN    NOT NULL DEFAULT FALSE,
    UNIQUE (session_id, term),
    CHECK (end_date > start_date)
);

CREATE TABLE course_offering (
    offering_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id       INTEGER  NOT NULL REFERENCES course(course_id),
    semester_id     SMALLINT NOT NULL REFERENCES semester(semester_id),
    lecturer_id     INTEGER  NOT NULL REFERENCES lecturer(lecturer_id),
    capacity        INTEGER  NOT NULL CHECK (capacity > 0),
    seats_taken     INTEGER  NOT NULL DEFAULT 0,
    UNIQUE (course_id, semester_id),
    CONSTRAINT seats_within_capacity CHECK (seats_taken BETWEEN 0 AND capacity)
);
-- grade bands must not overlap
CREATE TABLE grade_scale (
    grade_letter    CHAR(1)      PRIMARY KEY CHECK (grade_letter IN ('A','B','C','D','E','F')),
    score_range     NUMRANGE     NOT NULL,
    grade_point     NUMERIC(2,1) NOT NULL UNIQUE CHECK (grade_point BETWEEN 0 AND 5),
    remark          VARCHAR(20)  NOT NULL,
    EXCLUDE USING gist (score_range WITH &&)
);

-- grade is not stored; it comes from total_score via grade_scale
CREATE TABLE enrollment (
    enrollment_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id      INTEGER     NOT NULL REFERENCES student(student_id) ON DELETE RESTRICT,
    offering_id     INTEGER     NOT NULL REFERENCES course_offering(offering_id) ON DELETE RESTRICT,
    registered_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    status          VARCHAR(10) NOT NULL DEFAULT 'REGISTERED'
                       CHECK (status IN ('REGISTERED','DROPPED','COMPLETED')),
    ca_score        NUMERIC(4,1) CHECK (ca_score   BETWEEN 0 AND 30),
    exam_score      NUMERIC(4,1) CHECK (exam_score BETWEEN 0 AND 70),
    total_score     NUMERIC(4,1) GENERATED ALWAYS AS (ca_score + exam_score) STORED,
    result_status   VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                       CHECK (result_status IN ('PENDING','SUBMITTED','APPROVED')),
    graded_at       TIMESTAMPTZ,
    UNIQUE (student_id, offering_id),
    CHECK (status <> 'COMPLETED' OR (ca_score IS NOT NULL AND exam_score IS NOT NULL)),
    CHECK (result_status <> 'APPROVED' OR status = 'COMPLETED')
);

CREATE TABLE grade_audit (
    audit_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    enrollment_id   BIGINT       NOT NULL REFERENCES enrollment(enrollment_id) ON DELETE CASCADE,
    old_ca          NUMERIC(4,1),
    new_ca          NUMERIC(4,1),
    old_exam        NUMERIC(4,1),
    new_exam        NUMERIC(4,1),
    changed_by      TEXT         NOT NULL DEFAULT current_user,
    changed_at      TIMESTAMPTZ  NOT NULL DEFAULT clock_timestamp(),
    reason          TEXT
);

CREATE INDEX idx_department_faculty  ON department(faculty_id);
CREATE INDEX idx_programme_dept      ON programme(department_id);
CREATE INDEX idx_course_dept         ON course(department_id);
CREATE INDEX idx_prereq_prereq       ON course_prerequisite(prereq_course_id);
CREATE INDEX idx_semester_session    ON semester(session_id);

COMMENT ON TABLE  enrollment  IS 'Associative entity resolving the M:N between student and course_offering; carries the result.';
COMMENT ON COLUMN enrollment.total_score IS 'Derived (generated) column: ca_score + exam_score. Maintained by the DBMS, so no update anomaly.';
COMMENT ON TABLE  grade_scale IS 'NUC 5-point scale. EXCLUDE constraint prevents overlapping score bands.';
