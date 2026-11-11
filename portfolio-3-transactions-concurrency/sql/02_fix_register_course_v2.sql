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
    -- lock the student first so two registrations by the same student can't
    -- both pass the credit-limit check. order is always student -> offering.
    PERFORM 1 FROM student WHERE student_id = p_student_id FOR NO KEY UPDATE;

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

