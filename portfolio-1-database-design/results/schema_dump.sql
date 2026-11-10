--
-- PostgreSQL database dump
--

\restrict I5Iaar36dIkL11ojmgFdzLg8CzDA3kFxOQ9Lqw5ks5gNU0D9jCjK6aV0uvBpnAK

-- Dumped from database version 18.3 (Homebrew)
-- Dumped by pg_dump version 18.3 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS '';


--
-- Name: fn_cgpa(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_cgpa(p_student_id integer) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
    SELECT round(sum(g.grade_point * c.credit_units) / NULLIF(sum(c.credit_units), 0), 2)
    FROM enrollment e
    JOIN course_offering o ON o.offering_id = e.offering_id
    JOIN course c          ON c.course_id   = o.course_id
    JOIN grade_scale g     ON g.score_range @> e.total_score
    WHERE e.student_id = p_student_id
      AND e.status = 'COMPLETED'
      AND e.result_status = 'APPROVED';
$$;


--
-- Name: fn_degree_class(numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_degree_class(p_cgpa numeric) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE
        WHEN p_cgpa IS NULL  THEN 'No result'
        WHEN p_cgpa >= 4.50  THEN 'First Class'
        WHEN p_cgpa >= 3.50  THEN 'Second Class Upper'
        WHEN p_cgpa >= 2.40  THEN 'Second Class Lower'
        WHEN p_cgpa >= 1.50  THEN 'Third Class'
        WHEN p_cgpa >= 1.00  THEN 'Pass'
        ELSE 'Fail' END;
$$;


--
-- Name: fn_drop_course(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_drop_course(p_student_id integer, p_offering_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM 1 FROM course_offering WHERE offering_id = p_offering_id FOR UPDATE;
    UPDATE enrollment SET status = 'DROPPED'
    WHERE student_id = p_student_id AND offering_id = p_offering_id AND status = 'REGISTERED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active registration for student % in offering %', p_student_id, p_offering_id;
    END IF;
    UPDATE course_offering SET seats_taken = seats_taken - 1 WHERE offering_id = p_offering_id;
END $$;


--
-- Name: fn_register_course(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_register_course(p_student_id integer, p_offering_id integer) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: fn_semester_gpa(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_semester_gpa(p_student_id integer, p_semester_id integer) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: trg_grade_audit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_grade_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.ca_score IS DISTINCT FROM OLD.ca_score
       OR NEW.exam_score IS DISTINCT FROM OLD.exam_score THEN
        INSERT INTO grade_audit (enrollment_id, old_ca, new_ca, old_exam, new_exam, reason)
        VALUES (OLD.enrollment_id, OLD.ca_score, NEW.ca_score, OLD.exam_score, NEW.exam_score,
                current_setting('app.change_reason', true));
    END IF;
    RETURN NEW;
END $$;


--
-- Name: trg_protect_approved(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_protect_approved() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: academic_session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.academic_session (
    session_id smallint NOT NULL,
    name character(9) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    CONSTRAINT academic_session_check CHECK ((end_date > start_date)),
    CONSTRAINT academic_session_name_check CHECK (((name ~ '^[0-9]{4}/[0-9]{4}$'::text) AND ((substr((name)::text, 6, 4))::integer = ((substr((name)::text, 1, 4))::integer + 1))))
);


--
-- Name: academic_session_session_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.academic_session ALTER COLUMN session_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.academic_session_session_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: course; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course (
    course_id integer NOT NULL,
    course_code character(6) NOT NULL,
    title character varying(150) NOT NULL,
    department_id smallint NOT NULL,
    credit_units smallint NOT NULL,
    level smallint NOT NULL,
    term character varying(6) NOT NULL,
    CONSTRAINT course_check CHECK ((((substr((course_code)::text, 4, 1))::integer * 100) = level)),
    CONSTRAINT course_course_code_check CHECK ((course_code ~ '^[A-Z]{3}[1-6][0-9]{2}$'::text)),
    CONSTRAINT course_credit_units_check CHECK (((credit_units >= 1) AND (credit_units <= 6))),
    CONSTRAINT course_level_check CHECK ((level = ANY (ARRAY[100, 200, 300, 400, 500, 600]))),
    CONSTRAINT course_term_check CHECK (((term)::text = ANY ((ARRAY['FIRST'::character varying, 'SECOND'::character varying])::text[])))
);


--
-- Name: course_course_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.course ALTER COLUMN course_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.course_course_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: course_offering; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_offering (
    offering_id integer NOT NULL,
    course_id integer NOT NULL,
    semester_id smallint NOT NULL,
    lecturer_id integer NOT NULL,
    capacity integer NOT NULL,
    seats_taken integer DEFAULT 0 NOT NULL,
    CONSTRAINT course_offering_capacity_check CHECK ((capacity > 0)),
    CONSTRAINT seats_within_capacity CHECK (((seats_taken >= 0) AND (seats_taken <= capacity)))
);


--
-- Name: course_offering_offering_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.course_offering ALTER COLUMN offering_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.course_offering_offering_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: course_prerequisite; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_prerequisite (
    course_id integer NOT NULL,
    prereq_course_id integer NOT NULL,
    CONSTRAINT course_prerequisite_check CHECK ((course_id <> prereq_course_id))
);


--
-- Name: department; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.department (
    department_id smallint NOT NULL,
    faculty_id smallint NOT NULL,
    code character(3) NOT NULL,
    name character varying(120) NOT NULL,
    CONSTRAINT department_code_check CHECK ((code ~ '^[A-Z]{3}$'::text))
);


--
-- Name: department_department_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.department ALTER COLUMN department_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.department_department_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: enrollment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enrollment (
    enrollment_id bigint NOT NULL,
    student_id integer NOT NULL,
    offering_id integer NOT NULL,
    registered_at timestamp with time zone DEFAULT now() NOT NULL,
    status character varying(10) DEFAULT 'REGISTERED'::character varying NOT NULL,
    ca_score numeric(4,1),
    exam_score numeric(4,1),
    total_score numeric(4,1) GENERATED ALWAYS AS ((ca_score + exam_score)) STORED,
    result_status character varying(10) DEFAULT 'PENDING'::character varying NOT NULL,
    graded_at timestamp with time zone,
    CONSTRAINT enrollment_ca_score_check CHECK (((ca_score >= (0)::numeric) AND (ca_score <= (30)::numeric))),
    CONSTRAINT enrollment_check CHECK ((((status)::text <> 'COMPLETED'::text) OR ((ca_score IS NOT NULL) AND (exam_score IS NOT NULL)))),
    CONSTRAINT enrollment_check1 CHECK ((((result_status)::text <> 'APPROVED'::text) OR ((status)::text = 'COMPLETED'::text))),
    CONSTRAINT enrollment_exam_score_check CHECK (((exam_score >= (0)::numeric) AND (exam_score <= (70)::numeric))),
    CONSTRAINT enrollment_result_status_check CHECK (((result_status)::text = ANY ((ARRAY['PENDING'::character varying, 'SUBMITTED'::character varying, 'APPROVED'::character varying])::text[]))),
    CONSTRAINT enrollment_status_check CHECK (((status)::text = ANY ((ARRAY['REGISTERED'::character varying, 'DROPPED'::character varying, 'COMPLETED'::character varying])::text[])))
);


--
-- Name: TABLE enrollment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.enrollment IS 'Associative entity resolving the M:N between student and course_offering; carries the result.';


--
-- Name: COLUMN enrollment.total_score; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.enrollment.total_score IS 'Derived (generated) column: ca_score + exam_score. Maintained by the DBMS, so no update anomaly.';


--
-- Name: enrollment_enrollment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.enrollment ALTER COLUMN enrollment_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.enrollment_enrollment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: faculty; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.faculty (
    faculty_id smallint NOT NULL,
    code character varying(10) NOT NULL,
    name character varying(120) NOT NULL
);


--
-- Name: faculty_faculty_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.faculty ALTER COLUMN faculty_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.faculty_faculty_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: grade_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.grade_audit (
    audit_id bigint NOT NULL,
    enrollment_id bigint NOT NULL,
    old_ca numeric(4,1),
    new_ca numeric(4,1),
    old_exam numeric(4,1),
    new_exam numeric(4,1),
    changed_by text DEFAULT CURRENT_USER NOT NULL,
    changed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    reason text
);


--
-- Name: grade_audit_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.grade_audit ALTER COLUMN audit_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.grade_audit_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: grade_scale; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.grade_scale (
    grade_letter character(1) NOT NULL,
    score_range numrange NOT NULL,
    grade_point numeric(2,1) NOT NULL,
    remark character varying(20) NOT NULL,
    CONSTRAINT grade_scale_grade_letter_check CHECK ((grade_letter = ANY (ARRAY['A'::bpchar, 'B'::bpchar, 'C'::bpchar, 'D'::bpchar, 'E'::bpchar, 'F'::bpchar]))),
    CONSTRAINT grade_scale_grade_point_check CHECK (((grade_point >= (0)::numeric) AND (grade_point <= (5)::numeric)))
);


--
-- Name: TABLE grade_scale; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.grade_scale IS 'NUC 5-point scale. EXCLUDE constraint prevents overlapping score bands.';


--
-- Name: lecturer; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lecturer (
    lecturer_id integer NOT NULL,
    staff_no character varying(12) NOT NULL,
    department_id smallint NOT NULL,
    title character varying(10) NOT NULL,
    first_name character varying(60) NOT NULL,
    last_name character varying(60) NOT NULL,
    email character varying(120) NOT NULL,
    academic_rank character varying(30) NOT NULL,
    hire_date date NOT NULL,
    CONSTRAINT lecturer_academic_rank_check CHECK (((academic_rank)::text = ANY ((ARRAY['Assistant Lecturer'::character varying, 'Lecturer II'::character varying, 'Lecturer I'::character varying, 'Senior Lecturer'::character varying, 'Associate Professor'::character varying, 'Professor'::character varying])::text[]))),
    CONSTRAINT lecturer_email_check CHECK (((email)::text ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'::text)),
    CONSTRAINT lecturer_staff_no_check CHECK (((staff_no)::text ~ '^SP/[0-9]{5}$'::text)),
    CONSTRAINT lecturer_title_check CHECK (((title)::text = ANY ((ARRAY['Mr'::character varying, 'Mrs'::character varying, 'Ms'::character varying, 'Dr'::character varying, 'Prof'::character varying])::text[])))
);


--
-- Name: lecturer_lecturer_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lecturer ALTER COLUMN lecturer_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lecturer_lecturer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: programme; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.programme (
    programme_id smallint NOT NULL,
    department_id smallint NOT NULL,
    code character varying(12) NOT NULL,
    name character varying(150) NOT NULL,
    award character varying(10) NOT NULL,
    duration_years smallint NOT NULL,
    CONSTRAINT programme_award_check CHECK (((award)::text = ANY ((ARRAY['BSc'::character varying, 'BEng'::character varying, 'BA'::character varying, 'MSc'::character varying, 'MIT'::character varying, 'PGD'::character varying])::text[]))),
    CONSTRAINT programme_duration_years_check CHECK (((duration_years >= 1) AND (duration_years <= 6)))
);


--
-- Name: programme_programme_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.programme ALTER COLUMN programme_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.programme_programme_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: semester; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.semester (
    semester_id smallint NOT NULL,
    session_id smallint NOT NULL,
    term character varying(6) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    registration_open boolean DEFAULT false NOT NULL,
    results_published boolean DEFAULT false NOT NULL,
    CONSTRAINT semester_check CHECK ((end_date > start_date)),
    CONSTRAINT semester_term_check CHECK (((term)::text = ANY ((ARRAY['FIRST'::character varying, 'SECOND'::character varying])::text[])))
);


--
-- Name: semester_semester_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.semester ALTER COLUMN semester_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.semester_semester_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: student; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student (
    student_id integer NOT NULL,
    matric_no character varying(15) NOT NULL,
    programme_id smallint NOT NULL,
    first_name character varying(60) NOT NULL,
    last_name character varying(60) NOT NULL,
    gender character(1) NOT NULL,
    date_of_birth date NOT NULL,
    email character varying(120) NOT NULL,
    entry_year smallint NOT NULL,
    current_level smallint NOT NULL,
    status character varying(12) DEFAULT 'ACTIVE'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT student_check CHECK ((date_of_birth < make_date((entry_year - 14), 1, 1))),
    CONSTRAINT student_current_level_check CHECK ((current_level = ANY (ARRAY[100, 200, 300, 400, 500, 600]))),
    CONSTRAINT student_email_check CHECK (((email)::text ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'::text)),
    CONSTRAINT student_entry_year_check CHECK (((entry_year >= 2000) AND (entry_year <= 2100))),
    CONSTRAINT student_gender_check CHECK ((gender = ANY (ARRAY['M'::bpchar, 'F'::bpchar]))),
    CONSTRAINT student_matric_no_check CHECK (((matric_no)::text ~ '^AU/[0-9]{4}/[0-9]{5}$'::text)),
    CONSTRAINT student_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'PROBATION'::character varying, 'GRADUATED'::character varying, 'WITHDRAWN'::character varying, 'SUSPENDED'::character varying])::text[])))
);


--
-- Name: student_student_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.student ALTER COLUMN student_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.student_student_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: v_result; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_result AS
 SELECT e.enrollment_id,
    e.student_id,
    st.matric_no,
    (((st.first_name)::text || ' '::text) || (st.last_name)::text) AS student_name,
    ses.name AS session_name,
    sem.term,
    sem.semester_id,
    c.course_code,
    c.title AS course_title,
    c.credit_units,
    e.status,
    e.ca_score,
    e.exam_score,
    e.total_score,
    g.grade_letter,
    g.grade_point,
    (g.grade_point * (c.credit_units)::numeric) AS quality_points,
    e.result_status
   FROM ((((((public.enrollment e
     JOIN public.student st ON ((st.student_id = e.student_id)))
     JOIN public.course_offering o ON ((o.offering_id = e.offering_id)))
     JOIN public.course c ON ((c.course_id = o.course_id)))
     JOIN public.semester sem ON ((sem.semester_id = o.semester_id)))
     JOIN public.academic_session ses ON ((ses.session_id = sem.session_id)))
     LEFT JOIN public.grade_scale g ON ((g.score_range @> e.total_score)));


--
-- Name: v_transcript; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_transcript AS
 WITH sem AS (
         SELECT v_result.student_id,
            v_result.matric_no,
            v_result.student_name,
            v_result.session_name,
            v_result.term,
            v_result.semester_id,
            sum(v_result.credit_units) AS units_taken,
            sum(v_result.credit_units) FILTER (WHERE (v_result.grade_point > (0)::numeric)) AS units_passed,
            sum(v_result.quality_points) AS quality_points
           FROM public.v_result
          WHERE (((v_result.status)::text = 'COMPLETED'::text) AND ((v_result.result_status)::text = 'APPROVED'::text))
          GROUP BY v_result.student_id, v_result.matric_no, v_result.student_name, v_result.session_name, v_result.term, v_result.semester_id
        )
 SELECT student_id,
    matric_no,
    student_name,
    session_name,
    term,
    units_taken,
    units_passed,
    quality_points,
    round((quality_points / (units_taken)::numeric), 2) AS gpa,
    round((sum(quality_points) OVER w / sum(units_taken) OVER w), 2) AS cgpa
   FROM sem
  WINDOW w AS (PARTITION BY student_id ORDER BY semester_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);


--
-- Name: academic_session academic_session_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academic_session
    ADD CONSTRAINT academic_session_name_key UNIQUE (name);


--
-- Name: academic_session academic_session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.academic_session
    ADD CONSTRAINT academic_session_pkey PRIMARY KEY (session_id);


--
-- Name: course course_course_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course
    ADD CONSTRAINT course_course_code_key UNIQUE (course_code);


--
-- Name: course_offering course_offering_course_id_semester_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_offering
    ADD CONSTRAINT course_offering_course_id_semester_id_key UNIQUE (course_id, semester_id);


--
-- Name: course_offering course_offering_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_offering
    ADD CONSTRAINT course_offering_pkey PRIMARY KEY (offering_id);


--
-- Name: course course_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course
    ADD CONSTRAINT course_pkey PRIMARY KEY (course_id);


--
-- Name: course_prerequisite course_prerequisite_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_prerequisite
    ADD CONSTRAINT course_prerequisite_pkey PRIMARY KEY (course_id, prereq_course_id);


--
-- Name: department department_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT department_code_key UNIQUE (code);


--
-- Name: department department_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT department_name_key UNIQUE (name);


--
-- Name: department department_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT department_pkey PRIMARY KEY (department_id);


--
-- Name: enrollment enrollment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollment
    ADD CONSTRAINT enrollment_pkey PRIMARY KEY (enrollment_id);


--
-- Name: enrollment enrollment_student_id_offering_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollment
    ADD CONSTRAINT enrollment_student_id_offering_id_key UNIQUE (student_id, offering_id);


--
-- Name: faculty faculty_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faculty
    ADD CONSTRAINT faculty_code_key UNIQUE (code);


--
-- Name: faculty faculty_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faculty
    ADD CONSTRAINT faculty_name_key UNIQUE (name);


--
-- Name: faculty faculty_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faculty
    ADD CONSTRAINT faculty_pkey PRIMARY KEY (faculty_id);


--
-- Name: grade_audit grade_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_audit
    ADD CONSTRAINT grade_audit_pkey PRIMARY KEY (audit_id);


--
-- Name: grade_scale grade_scale_grade_point_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_scale
    ADD CONSTRAINT grade_scale_grade_point_key UNIQUE (grade_point);


--
-- Name: grade_scale grade_scale_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_scale
    ADD CONSTRAINT grade_scale_pkey PRIMARY KEY (grade_letter);


--
-- Name: grade_scale grade_scale_score_range_excl; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_scale
    ADD CONSTRAINT grade_scale_score_range_excl EXCLUDE USING gist (score_range WITH &&);


--
-- Name: lecturer lecturer_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lecturer
    ADD CONSTRAINT lecturer_email_key UNIQUE (email);


--
-- Name: lecturer lecturer_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lecturer
    ADD CONSTRAINT lecturer_pkey PRIMARY KEY (lecturer_id);


--
-- Name: lecturer lecturer_staff_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lecturer
    ADD CONSTRAINT lecturer_staff_no_key UNIQUE (staff_no);


--
-- Name: programme programme_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.programme
    ADD CONSTRAINT programme_code_key UNIQUE (code);


--
-- Name: programme programme_department_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.programme
    ADD CONSTRAINT programme_department_id_name_key UNIQUE (department_id, name);


--
-- Name: programme programme_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.programme
    ADD CONSTRAINT programme_pkey PRIMARY KEY (programme_id);


--
-- Name: semester semester_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.semester
    ADD CONSTRAINT semester_pkey PRIMARY KEY (semester_id);


--
-- Name: semester semester_session_id_term_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.semester
    ADD CONSTRAINT semester_session_id_term_key UNIQUE (session_id, term);


--
-- Name: student student_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student
    ADD CONSTRAINT student_email_key UNIQUE (email);


--
-- Name: student student_matric_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student
    ADD CONSTRAINT student_matric_no_key UNIQUE (matric_no);


--
-- Name: student student_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student
    ADD CONSTRAINT student_pkey PRIMARY KEY (student_id);


--
-- Name: idx_course_dept; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_dept ON public.course USING btree (department_id);


--
-- Name: idx_department_faculty; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_department_faculty ON public.department USING btree (faculty_id);


--
-- Name: idx_prereq_prereq; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_prereq_prereq ON public.course_prerequisite USING btree (prereq_course_id);


--
-- Name: idx_programme_dept; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_programme_dept ON public.programme USING btree (department_id);


--
-- Name: idx_semester_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_semester_session ON public.semester USING btree (session_id);


--
-- Name: enrollment enrollment_grade_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enrollment_grade_audit AFTER UPDATE OF ca_score, exam_score ON public.enrollment FOR EACH ROW EXECUTE FUNCTION public.trg_grade_audit();


--
-- Name: enrollment enrollment_protect_approved; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enrollment_protect_approved BEFORE UPDATE ON public.enrollment FOR EACH ROW EXECUTE FUNCTION public.trg_protect_approved();


--
-- Name: course course_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course
    ADD CONSTRAINT course_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.department(department_id);


--
-- Name: course_offering course_offering_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_offering
    ADD CONSTRAINT course_offering_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.course(course_id);


--
-- Name: course_offering course_offering_lecturer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_offering
    ADD CONSTRAINT course_offering_lecturer_id_fkey FOREIGN KEY (lecturer_id) REFERENCES public.lecturer(lecturer_id);


--
-- Name: course_offering course_offering_semester_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_offering
    ADD CONSTRAINT course_offering_semester_id_fkey FOREIGN KEY (semester_id) REFERENCES public.semester(semester_id);


--
-- Name: course_prerequisite course_prerequisite_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_prerequisite
    ADD CONSTRAINT course_prerequisite_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.course(course_id) ON DELETE CASCADE;


--
-- Name: course_prerequisite course_prerequisite_prereq_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_prerequisite
    ADD CONSTRAINT course_prerequisite_prereq_course_id_fkey FOREIGN KEY (prereq_course_id) REFERENCES public.course(course_id) ON DELETE CASCADE;


--
-- Name: department department_faculty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT department_faculty_id_fkey FOREIGN KEY (faculty_id) REFERENCES public.faculty(faculty_id) ON DELETE RESTRICT;


--
-- Name: enrollment enrollment_offering_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollment
    ADD CONSTRAINT enrollment_offering_id_fkey FOREIGN KEY (offering_id) REFERENCES public.course_offering(offering_id) ON DELETE RESTRICT;


--
-- Name: enrollment enrollment_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollment
    ADD CONSTRAINT enrollment_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.student(student_id) ON DELETE RESTRICT;


--
-- Name: grade_audit grade_audit_enrollment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_audit
    ADD CONSTRAINT grade_audit_enrollment_id_fkey FOREIGN KEY (enrollment_id) REFERENCES public.enrollment(enrollment_id) ON DELETE CASCADE;


--
-- Name: lecturer lecturer_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lecturer
    ADD CONSTRAINT lecturer_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.department(department_id);


--
-- Name: programme programme_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.programme
    ADD CONSTRAINT programme_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.department(department_id) ON DELETE RESTRICT;


--
-- Name: semester semester_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.semester
    ADD CONSTRAINT semester_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.academic_session(session_id);


--
-- Name: student student_programme_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student
    ADD CONSTRAINT student_programme_id_fkey FOREIGN KEY (programme_id) REFERENCES public.programme(programme_id);


--
-- Name: enrollment; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.enrollment ENABLE ROW LEVEL SECURITY;

--
-- Name: enrollment lecturer_own_course; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lecturer_own_course ON public.enrollment TO uni_lecturer USING ((offering_id IN ( SELECT course_offering.offering_id
   FROM public.course_offering
  WHERE (course_offering.lecturer_id = (current_setting('app.lecturer_id'::text, true))::integer))));


--
-- Name: enrollment registrar_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY registrar_all ON public.enrollment TO uni_registrar USING (true) WITH CHECK (true);


--
-- Name: enrollment student_own_results; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY student_own_results ON public.enrollment FOR SELECT TO uni_student USING (((student_id = (current_setting('app.student_id'::text, true))::integer) AND ((result_status)::text = 'APPROVED'::text)));


--
-- PostgreSQL database dump complete
--

\unrestrict I5Iaar36dIkL11ojmgFdzLg8CzDA3kFxOQ9Lqw5ks5gNU0D9jCjK6aV0uvBpnAK

