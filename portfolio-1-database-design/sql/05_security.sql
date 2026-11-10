-- the app sets app.lecturer_id / app.student_id per session
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'uni_registrar') THEN CREATE ROLE uni_registrar NOLOGIN; END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'uni_lecturer')  THEN CREATE ROLE uni_lecturer  NOLOGIN; END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'uni_student')   THEN CREATE ROLE uni_student   NOLOGIN; END IF;
END $$;

GRANT USAGE ON SCHEMA public TO uni_registrar, uni_lecturer, uni_student;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO uni_registrar;

GRANT SELECT ON faculty, department, programme, course, course_prerequisite,
               academic_session, semester, course_offering, grade_scale, student, lecturer
      TO uni_lecturer;
GRANT SELECT ON enrollment TO uni_lecturer;
GRANT UPDATE (ca_score, exam_score, status, result_status) ON enrollment TO uni_lecturer;
GRANT INSERT ON grade_audit TO uni_lecturer;   -- audit trigger

GRANT SELECT ON course, semester, academic_session, course_offering, grade_scale, enrollment TO uni_student;
ALTER TABLE enrollment ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS registrar_all       ON enrollment;
DROP POLICY IF EXISTS lecturer_own_course ON enrollment;
DROP POLICY IF EXISTS student_own_results ON enrollment;

CREATE POLICY registrar_all ON enrollment
    TO uni_registrar USING (true) WITH CHECK (true);

CREATE POLICY lecturer_own_course ON enrollment
    TO uni_lecturer
    USING (offering_id IN (SELECT offering_id FROM course_offering
                           WHERE lecturer_id = current_setting('app.lecturer_id', true)::int));

CREATE POLICY student_own_results ON enrollment
    FOR SELECT TO uni_student
    USING (student_id = current_setting('app.student_id', true)::int
           AND result_status = 'APPROVED');
