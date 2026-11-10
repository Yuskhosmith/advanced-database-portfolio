CREATE OR REPLACE VIEW v_result AS
SELECT e.enrollment_id,
       e.student_id,
       st.matric_no,
       st.first_name || ' ' || st.last_name AS student_name,
       ses.name              AS session_name,
       sem.term,
       sem.semester_id,
       c.course_code,
       c.title               AS course_title,
       c.credit_units,
       e.status,
       e.ca_score,
       e.exam_score,
       e.total_score,
       g.grade_letter,
       g.grade_point,
       g.grade_point * c.credit_units AS quality_points,
       e.result_status
FROM enrollment e
JOIN student          st  ON st.student_id   = e.student_id
JOIN course_offering  o   ON o.offering_id   = e.offering_id
JOIN course           c   ON c.course_id     = o.course_id
JOIN semester         sem ON sem.semester_id = o.semester_id
JOIN academic_session ses ON ses.session_id  = sem.session_id
LEFT JOIN grade_scale g   ON g.score_range @> e.total_score;
CREATE OR REPLACE FUNCTION fn_semester_gpa(p_student_id int, p_semester_id int)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT round(sum(g.grade_point * c.credit_units) / NULLIF(sum(c.credit_units), 0), 2)
    FROM enrollment e
    JOIN course_offering o ON o.offering_id = e.offering_id
    JOIN course c          ON c.course_id   = o.course_id
    JOIN grade_scale g     ON g.score_range @> e.total_score
    WHERE e.student_id  = p_student_id
      AND o.semester_id = p_semester_id
      AND e.status      = 'COMPLETED'
      AND e.result_status = 'APPROVED';
$$;

CREATE OR REPLACE FUNCTION fn_cgpa(p_student_id int)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT round(sum(g.grade_point * c.credit_units) / NULLIF(sum(c.credit_units), 0), 2)
    FROM enrollment e
    JOIN course_offering o ON o.offering_id = e.offering_id
    JOIN course c          ON c.course_id   = o.course_id
    JOIN grade_scale g     ON g.score_range @> e.total_score
    WHERE e.student_id = p_student_id
      AND e.status = 'COMPLETED'
      AND e.result_status = 'APPROVED';
$$;

CREATE OR REPLACE FUNCTION fn_degree_class(p_cgpa numeric)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_cgpa IS NULL  THEN 'No result'
        WHEN p_cgpa >= 4.50  THEN 'First Class'
        WHEN p_cgpa >= 3.50  THEN 'Second Class Upper'
        WHEN p_cgpa >= 2.40  THEN 'Second Class Lower'
        WHEN p_cgpa >= 1.50  THEN 'Third Class'
        WHEN p_cgpa >= 1.00  THEN 'Pass'
        ELSE 'Fail' END;
$$;
CREATE OR REPLACE VIEW v_transcript AS
WITH sem AS (
    SELECT student_id, matric_no, student_name, session_name, term, semester_id,
           sum(credit_units)   AS units_taken,
           sum(credit_units) FILTER (WHERE grade_point > 0) AS units_passed,
           sum(quality_points) AS quality_points
    FROM v_result
    WHERE status = 'COMPLETED' AND result_status = 'APPROVED'
    GROUP BY student_id, matric_no, student_name, session_name, term, semester_id
)
SELECT student_id, matric_no, student_name, session_name, term,
       units_taken, units_passed, quality_points,
       round(quality_points / units_taken, 2) AS gpa,
       round(sum(quality_points) OVER w / sum(units_taken) OVER w, 2) AS cgpa
FROM sem
WINDOW w AS (PARTITION BY student_id ORDER BY semester_id
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);
-- reason can be passed with SET LOCAL app.change_reason
CREATE OR REPLACE FUNCTION trg_grade_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ca_score IS DISTINCT FROM OLD.ca_score
       OR NEW.exam_score IS DISTINCT FROM OLD.exam_score THEN
        INSERT INTO grade_audit (enrollment_id, old_ca, new_ca, old_exam, new_exam, reason)
        VALUES (OLD.enrollment_id, OLD.ca_score, NEW.ca_score, OLD.exam_score, NEW.exam_score,
                current_setting('app.change_reason', true));
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER enrollment_grade_audit
AFTER UPDATE OF ca_score, exam_score ON enrollment
FOR EACH ROW EXECUTE FUNCTION trg_grade_audit();
-- approved results can only change with app.senate_override = 'on'
CREATE OR REPLACE FUNCTION trg_protect_approved() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.result_status = 'APPROVED'
       AND (NEW.ca_score IS DISTINCT FROM OLD.ca_score OR NEW.exam_score IS DISTINCT FROM OLD.exam_score)
       AND coalesce(current_setting('app.senate_override', true), 'off') <> 'on' THEN
        RAISE EXCEPTION 'Result % is APPROVED and cannot be changed without Senate override',
              OLD.enrollment_id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.ca_score IS DISTINCT FROM OLD.ca_score OR NEW.exam_score IS DISTINCT FROM OLD.exam_score THEN
        NEW.graded_at := now();
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER enrollment_protect_approved
BEFORE UPDATE ON enrollment
FOR EACH ROW EXECUTE FUNCTION trg_protect_approved();
CREATE OR REPLACE FUNCTION fn_register_course(p_student_id int, p_offering_id int)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_off        course_offering%ROWTYPE;
    v_course     course%ROWTYPE;
    v_open       boolean;
    v_units      int;
    v_missing    text;
    v_enrollment bigint;
    c_max_units  CONSTANT int := 24;
BEGIN
    SELECT * INTO v_off FROM course_offering WHERE offering_id = p_offering_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Offering % does not exist', p_offering_id;
    END IF;
    SELECT * INTO v_course FROM course WHERE course_id = v_off.course_id;

    SELECT registration_open INTO v_open FROM semester WHERE semester_id = v_off.semester_id;
    IF NOT v_open THEN
        RAISE EXCEPTION 'Registration is closed for this semester';
    END IF;

    IF v_off.seats_taken >= v_off.capacity THEN
        RAISE EXCEPTION 'Course % is full (% / %)', v_course.course_code, v_off.seats_taken, v_off.capacity
              USING ERRCODE = 'AU001';
    END IF;

    -- all prerequisites passed
    SELECT string_agg(pc.course_code, ', ') INTO v_missing
    FROM course_prerequisite cp
    JOIN course pc ON pc.course_id = cp.prereq_course_id
    WHERE cp.course_id = v_course.course_id
      AND NOT EXISTS (
          SELECT 1 FROM enrollment e
          JOIN course_offering o ON o.offering_id = e.offering_id
          WHERE e.student_id = p_student_id
            AND o.course_id  = cp.prereq_course_id
            AND e.status = 'COMPLETED'
            AND e.total_score >= 40);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Prerequisite(s) not passed: %', v_missing USING ERRCODE = 'AU002';
    END IF;

    SELECT coalesce(sum(c.credit_units), 0) INTO v_units
    FROM enrollment e
    JOIN course_offering o ON o.offering_id = e.offering_id
    JOIN course c          ON c.course_id   = o.course_id
    WHERE e.student_id = p_student_id AND o.semester_id = v_off.semester_id
      AND e.status <> 'DROPPED';
    IF v_units + v_course.credit_units > c_max_units THEN
        RAISE EXCEPTION 'Credit limit exceeded: % + % > %', v_units, v_course.credit_units, c_max_units
              USING ERRCODE = 'AU003';
    END IF;

    INSERT INTO enrollment (student_id, offering_id) VALUES (p_student_id, p_offering_id)
    RETURNING enrollment_id INTO v_enrollment;

    UPDATE course_offering SET seats_taken = seats_taken + 1 WHERE offering_id = p_offering_id;
    RETURN v_enrollment;
END $$;

CREATE OR REPLACE FUNCTION fn_drop_course(p_student_id int, p_offering_id int)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM course_offering WHERE offering_id = p_offering_id FOR UPDATE;
    UPDATE enrollment SET status = 'DROPPED'
    WHERE student_id = p_student_id AND offering_id = p_offering_id AND status = 'REGISTERED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active registration for student % in offering %', p_student_id, p_offering_id;
    END IF;
    UPDATE course_offering SET seats_taken = seats_taken - 1 WHERE offering_id = p_offering_id;
END $$;
