-- Q02, Q05, Q06 (covering, so Q05 can use an index-only scan)
CREATE INDEX idx_enrollment_offering_cover
    ON enrollment (offering_id) INCLUDE (status, total_score);

-- Q08
CREATE INDEX idx_enrollment_pending
    ON enrollment (offering_id) WHERE result_status = 'PENDING';

CREATE INDEX idx_offering_semester ON course_offering (semester_id);
CREATE INDEX idx_offering_lecturer ON course_offering (lecturer_id);

CREATE INDEX idx_student_programme ON student (programme_id);

-- Q07: text_pattern_ops so LIKE 'abc%' can use it
CREATE INDEX idx_student_lower_name
    ON student (lower(last_name) text_pattern_ops, lower(first_name) text_pattern_ops);

-- Q10: entry_year and current_level are correlated
CREATE STATISTICS st_student_cohort (dependencies, ndistinct) ON entry_year, current_level FROM student;

-- Q03: refresh after results are approved (unique index needed for CONCURRENTLY)
CREATE MATERIALIZED VIEW mv_student_cgpa AS
SELECT s.student_id, s.matric_no, s.first_name || ' ' || s.last_name AS student_name,
       s.status, d.department_id, d.code AS dept_code,
       sum(c.credit_units) AS units,
       round(sum(g.grade_point * c.credit_units) / sum(c.credit_units), 2) AS cgpa
FROM enrollment e
JOIN course_offering o ON o.offering_id = e.offering_id
JOIN course c          ON c.course_id   = o.course_id
JOIN grade_scale g     ON g.score_range @> e.total_score
JOIN student s         ON s.student_id  = e.student_id
JOIN programme p       ON p.programme_id = s.programme_id
JOIN department d      ON d.department_id = p.department_id
WHERE e.status = 'COMPLETED' AND e.result_status = 'APPROVED'
GROUP BY s.student_id, s.matric_no, s.first_name, s.last_name, s.status, d.department_id, d.code;

CREATE UNIQUE INDEX ux_mv_student_cgpa ON mv_student_cgpa (student_id);
CREATE INDEX idx_mv_cgpa_dept ON mv_student_cgpa (department_id, cgpa DESC) WHERE status = 'ACTIVE';

VACUUM ANALYZE;
