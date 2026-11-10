DROP MATERIALIZED VIEW IF EXISTS mv_student_cgpa;
DROP INDEX IF EXISTS idx_enrollment_offering_cover;
DROP INDEX IF EXISTS idx_enrollment_pending;
DROP INDEX IF EXISTS idx_offering_semester;
DROP INDEX IF EXISTS idx_offering_lecturer;
DROP INDEX IF EXISTS idx_student_programme;
DROP INDEX IF EXISTS idx_student_lower_name;
DROP STATISTICS IF EXISTS st_student_cohort;
VACUUM ANALYZE;
