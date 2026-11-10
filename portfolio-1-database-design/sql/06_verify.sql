\pset footer off

\echo '=== 1. Row counts ==='
SELECT 'faculty' AS table_name, count(*) FROM faculty UNION ALL
SELECT 'department', count(*) FROM department UNION ALL
SELECT 'programme', count(*) FROM programme UNION ALL
SELECT 'lecturer', count(*) FROM lecturer UNION ALL
SELECT 'student', count(*) FROM student UNION ALL
SELECT 'course', count(*) FROM course UNION ALL
SELECT 'course_prerequisite', count(*) FROM course_prerequisite UNION ALL
SELECT 'academic_session', count(*) FROM academic_session UNION ALL
SELECT 'semester', count(*) FROM semester UNION ALL
SELECT 'course_offering', count(*) FROM course_offering UNION ALL
SELECT 'grade_scale', count(*) FROM grade_scale UNION ALL
SELECT 'enrollment', count(*) FROM enrollment;

\echo '=== 2. Integrity tests (each must be REJECTED by the DBMS) ==='
CREATE OR REPLACE FUNCTION pg_temp.expect_error(p_label text, p_sql text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN 'FAIL  ' || p_label || ' -> statement was accepted!';
EXCEPTION WHEN OTHERS THEN
    RETURN 'PASS  ' || p_label || ' -> [' || SQLSTATE || '] ' || SQLERRM;
END $$;

SELECT pg_temp.expect_error('T01 exam score above 70',
  $q$UPDATE enrollment SET exam_score = 75 WHERE enrollment_id = (SELECT min(enrollment_id) FROM enrollment WHERE status='REGISTERED')$q$) AS result
UNION ALL SELECT pg_temp.expect_error('T02 overlapping grade band',
  $q$UPDATE grade_scale SET score_range = '[0,42)' WHERE grade_letter = 'F'$q$)
UNION ALL SELECT pg_temp.expect_error('T03 duplicate registration',
  $q$INSERT INTO enrollment (student_id, offering_id) SELECT student_id, offering_id FROM enrollment LIMIT 1$q$)
UNION ALL SELECT pg_temp.expect_error('T04 enrollment for unknown student (FK)',
  $q$INSERT INTO enrollment (student_id, offering_id) VALUES (999999, 1)$q$)
UNION ALL SELECT pg_temp.expect_error('T05 malformed matric number',
  $q$INSERT INTO student (matric_no, programme_id, first_name, last_name, gender, date_of_birth, email, entry_year, current_level)
     VALUES ('2026-123', 1, 'Test', 'User', 'M', '2005-01-01', 't@x.com', 2026, 100)$q$)
UNION ALL SELECT pg_temp.expect_error('T06 course code does not match level',
  $q$INSERT INTO course (course_code, title, department_id, credit_units, level, term) VALUES ('CSC199','X',1,3,200,'FIRST')$q$)
UNION ALL SELECT pg_temp.expect_error('T07 seats above capacity',
  $q$UPDATE course_offering SET seats_taken = capacity + 1 WHERE offering_id = 1$q$)
UNION ALL SELECT pg_temp.expect_error('T08 COMPLETED without scores',
  $q$UPDATE enrollment SET status = 'COMPLETED' WHERE enrollment_id = (SELECT min(enrollment_id) FROM enrollment WHERE status='REGISTERED')$q$)
UNION ALL SELECT pg_temp.expect_error('T09 change APPROVED result without Senate override',
  $q$UPDATE enrollment SET exam_score = 70 WHERE enrollment_id = 1$q$)
UNION ALL SELECT pg_temp.expect_error('T10 write to generated total_score',
  $q$UPDATE enrollment SET total_score = 100 WHERE enrollment_id = 1$q$)
UNION ALL SELECT pg_temp.expect_error('T11 course as its own prerequisite',
  $q$INSERT INTO course_prerequisite VALUES (1, 1)$q$)
UNION ALL SELECT pg_temp.expect_error('T12 delete a student who has results (RESTRICT)',
  $q$DELETE FROM student WHERE student_id = 1$q$)
UNION ALL SELECT pg_temp.expect_error('T13 session name years not consecutive',
  $q$INSERT INTO academic_session (name, start_date, end_date) VALUES ('2030/2032', '2030-09-01', '2031-08-01')$q$)
UNION ALL SELECT pg_temp.expect_error('T14 register for a closed (past) semester',
  $q$SELECT fn_register_course(1, (SELECT min(offering_id) FROM course_offering o JOIN semester s USING (semester_id) WHERE NOT s.registration_open))$q$);

\echo '=== 3. Every total score maps to exactly one grade (expect 0 rows unmatched) ==='
SELECT count(*) AS completed_results,
       count(*) FILTER (WHERE g.grade_letter IS NULL) AS unmatched
FROM enrollment e LEFT JOIN grade_scale g ON g.score_range @> e.total_score
WHERE e.status = 'COMPLETED';

\echo '=== 4. Grade distribution ==='
SELECT g.grade_letter, g.remark, count(*) AS results,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM enrollment e JOIN grade_scale g ON g.score_range @> e.total_score
GROUP BY g.grade_letter, g.remark ORDER BY g.grade_letter;

\echo '=== 5. Sample transcript (student 7) ==='
SELECT matric_no, student_name, session_name, term, units_taken, units_passed, gpa, cgpa
FROM v_transcript WHERE student_id = 7 ORDER BY session_name, term;

\echo '=== 6. Detailed results for student 7, first semester of entry ==='
SELECT session_name, term, course_code, credit_units AS cu, ca_score AS ca, exam_score AS exam,
       total_score AS total, grade_letter AS grade, grade_point AS gp
FROM v_result WHERE student_id = 7
ORDER BY semester_id, course_code LIMIT 6;

\echo '=== 7. CGPA and class of degree (functions) ==='
SELECT s.matric_no, s.status, fn_cgpa(s.student_id) AS cgpa, fn_degree_class(fn_cgpa(s.student_id)) AS class
FROM student s WHERE s.student_id IN (1, 7, 13, 19, 25) ORDER BY s.student_id;

\echo '=== 8. Prerequisite rule: a student who FAILED a 100L course cannot take the 200L follow-up ==='
SELECT e.student_id, c.course_code AS failed_course, e.total_score
FROM enrollment e JOIN course_offering o USING (offering_id) JOIN course c USING (course_id)
JOIN student s USING (student_id)
WHERE c.level = 100 AND right(c.course_code,2) = '05' AND e.total_score < 40
  AND s.current_level = 200 AND s.status IN ('ACTIVE','PROBATION')
ORDER BY e.student_id LIMIT 1 \gset fail_
SELECT pg_temp.expect_error('T15 register 200L course without passing ' || :'fail_failed_course',
  format($q$SELECT fn_register_course(%s, (SELECT o.offering_id FROM course_offering o JOIN course c USING (course_id)
          JOIN semester s USING (semester_id) WHERE s.registration_open
          AND c.course_code = %L))$q$, :fail_student_id,
          left(:'fail_failed_course', 3) || '205')) AS result;

\echo '=== 9. Row-level security: lecturer only sees enrollments for offerings they teach ==='
BEGIN;
SET LOCAL ROLE uni_lecturer;
SET LOCAL app.lecturer_id = '1';
SELECT count(*) AS visible_enrollments_for_lecturer_1,
       count(DISTINCT offering_id) AS offerings
FROM enrollment;
ROLLBACK;
SELECT count(*) AS actual_enrollments_taught_by_lecturer_1
FROM enrollment e JOIN course_offering o USING (offering_id) WHERE o.lecturer_id = 1;

BEGIN;
SET LOCAL ROLE uni_student;
SET LOCAL app.student_id = '7';
SELECT count(*) AS rows_visible_to_student_7, count(DISTINCT student_id) AS distinct_students FROM enrollment;
SELECT pg_temp.expect_error('T16 student tries to change own score',
  $q$UPDATE enrollment SET exam_score = 70 WHERE student_id = 7$q$) AS result;
ROLLBACK;

\echo '=== 10. Database size ==='
SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size,
       pg_size_pretty(pg_total_relation_size('enrollment')) AS enrollment_table_size;
