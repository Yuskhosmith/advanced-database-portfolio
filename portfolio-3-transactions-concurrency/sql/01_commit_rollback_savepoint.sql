\pset footer off
\set ON_ERROR_STOP off
\set VERBOSITY terse

DROP TABLE IF EXISTS demo_batch;
CREATE TEMP TABLE demo_batch AS
SELECT e.enrollment_id, s.matric_no
FROM enrollment e
JOIN student s USING (student_id)
JOIN course_offering o USING (offering_id)
JOIN course c USING (course_id)
JOIN semester sem USING (semester_id)
WHERE c.course_code = 'CSC401' AND sem.registration_open
ORDER BY s.matric_no LIMIT 5;

-- reset so the script can be re-run
UPDATE enrollment SET ca_score = NULL, exam_score = NULL, status = 'REGISTERED', result_status = 'PENDING'
WHERE enrollment_id IN (SELECT enrollment_id FROM demo_batch);
DELETE FROM grade_audit WHERE enrollment_id IN (SELECT enrollment_id FROM demo_batch);

\echo '--- Starting state'
SELECT b.matric_no, e.ca_score, e.exam_score, e.total_score, e.status, e.result_status
FROM demo_batch b JOIN enrollment e USING (enrollment_id) ORDER BY b.matric_no;
\echo ''
\echo '=== A1. COMMIT: whole batch of 3 scores is written atomically ==='
BEGIN;
SET LOCAL app.change_reason = 'A1 initial upload';
UPDATE enrollment e SET ca_score = v.ca, exam_score = v.exam, status = 'COMPLETED', result_status = 'SUBMITTED'
FROM (VALUES (1, 25, 52), (2, 18, 40), (3, 28, 61)) AS v(rn, ca, exam)
JOIN (SELECT enrollment_id, row_number() OVER (ORDER BY matric_no) rn FROM demo_batch) b USING (rn)
WHERE e.enrollment_id = b.enrollment_id;
\echo 'inside the transaction, txid:'
SELECT pg_current_xact_id() AS txid, now() AS tx_started;
COMMIT;

SELECT b.matric_no, e.ca_score, e.exam_score, e.total_score, e.status, e.result_status,
       e.xmin AS created_by_txid
FROM demo_batch b JOIN enrollment e USING (enrollment_id) ORDER BY b.matric_no;
\echo 'audit trail written by trigger in the SAME transaction:'
SELECT a.enrollment_id, a.old_ca, a.new_ca, a.old_exam, a.new_exam, a.reason
FROM grade_audit a WHERE enrollment_id IN (SELECT enrollment_id FROM demo_batch) ORDER BY audit_id;
\echo ''
\echo '=== A2. ROLLBACK on error: one invalid score (exam 75 > 70) aborts the whole batch ==='
BEGIN;
SET LOCAL app.change_reason = 'A2 second upload';
UPDATE enrollment SET ca_score = 20, exam_score = 50, status = 'COMPLETED', result_status = 'SUBMITTED'
WHERE enrollment_id = (SELECT enrollment_id FROM demo_batch ORDER BY matric_no OFFSET 3 LIMIT 1);
\echo 'row 4 updated inside transaction:'
SELECT b.matric_no, e.total_score FROM demo_batch b JOIN enrollment e USING (enrollment_id) ORDER BY b.matric_no OFFSET 3 LIMIT 1;
UPDATE enrollment SET ca_score = 20, exam_score = 75, status = 'COMPLETED', result_status = 'SUBMITTED'
WHERE enrollment_id = (SELECT enrollment_id FROM demo_batch ORDER BY matric_no OFFSET 4 LIMIT 1);
\echo 'any further statement in an aborted transaction is refused:'
SELECT 1;
ROLLBACK;
\echo 'after ROLLBACK, row 4 is back to NULL (atomicity: nothing from A2 survived):'
SELECT b.matric_no, e.ca_score, e.exam_score, e.total_score, e.status
FROM demo_batch b JOIN enrollment e USING (enrollment_id) ORDER BY b.matric_no;
\echo ''
\echo '=== A3. SAVEPOINT: keep the valid row, undo only the invalid one ==='
BEGIN;
SET LOCAL app.change_reason = 'A3 upload with savepoints';
SAVEPOINT row4;
UPDATE enrollment SET ca_score = 20, exam_score = 50, status = 'COMPLETED', result_status = 'SUBMITTED'
WHERE enrollment_id = (SELECT enrollment_id FROM demo_batch ORDER BY matric_no OFFSET 3 LIMIT 1);
RELEASE SAVEPOINT row4;
SAVEPOINT row5;
UPDATE enrollment SET ca_score = 20, exam_score = 75, status = 'COMPLETED', result_status = 'SUBMITTED'
WHERE enrollment_id = (SELECT enrollment_id FROM demo_batch ORDER BY matric_no OFFSET 4 LIMIT 1);
ROLLBACK TO SAVEPOINT row5;
\echo 'transaction is usable again after ROLLBACK TO SAVEPOINT:'
SELECT 'still in transaction' AS state, pg_current_xact_id() AS txid;
COMMIT;
SELECT b.matric_no, e.ca_score, e.exam_score, e.total_score, e.status
FROM demo_batch b JOIN enrollment e USING (enrollment_id) ORDER BY b.matric_no;
\echo ''
\echo '=== A4. Business transaction: "swap course" = DROP one course + REGISTER another ==='
\echo 'The new course is full, so the drop must be undone too (all-or-nothing).'
SELECT e.student_id, e.offering_id AS drop_offering
FROM enrollment e JOIN course_offering o USING (offering_id) JOIN semester s USING (semester_id)
JOIN course c USING (course_id)
WHERE s.registration_open AND c.course_code = 'CSC404' ORDER BY e.student_id LIMIT 1 \gset
SELECT o.offering_id AS full_offering FROM course_offering o JOIN course c USING (course_id)
JOIN semester s USING (semester_id) WHERE s.registration_open AND c.course_code = 'MTH101' \gset
-- make MTH101 full
UPDATE course_offering SET capacity = seats_taken WHERE offering_id = :full_offering;

SELECT :student_id AS student_id, :drop_offering AS drop_offering, :full_offering AS full_offering;
BEGIN;
SELECT fn_drop_course(:student_id, :drop_offering);
SELECT status AS csc404_status_inside_tx FROM enrollment WHERE student_id = :student_id AND offering_id = :drop_offering;
SELECT fn_register_course(:student_id, :full_offering);
ROLLBACK;
SELECT status AS csc404_status_after_rollback,
       (SELECT seats_taken FROM course_offering WHERE offering_id = :drop_offering) AS csc404_seats
FROM enrollment WHERE student_id = :student_id AND offering_id = :drop_offering;
UPDATE course_offering SET capacity = seats_taken + 25 WHERE offering_id = :full_offering;
\echo ''
\echo '=== A5. Durability evidence: committed work is in the WAL ==='
SELECT pg_current_wal_lsn() AS current_wal_lsn,
       pg_walfile_name(pg_current_wal_lsn()) AS wal_file,
       current_setting('synchronous_commit') AS synchronous_commit,
       current_setting('fsync') AS fsync;
