-- generated test data (fixed seed so runs are repeatable)
SELECT setseed(0.8103);

-- Box-Muller
CREATE OR REPLACE FUNCTION pg_temp.rnorm() RETURNS double precision
LANGUAGE sql VOLATILE AS
$$ SELECT sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()) $$;

CREATE TEMP TABLE first_names(n text[]);
INSERT INTO first_names VALUES (ARRAY[
 'Adebayo','Chinedu','Emeka','Ifeoma','Ngozi','Oluwaseun','Tunde','Amaka','Bola','Chiamaka',
 'Damilola','Efosa','Funmilayo','Garba','Halima','Ibrahim','Jumoke','Kelechi','Lami','Musa',
 'Nkechi','Obinna','Precious','Rukayat','Sadiq','Temitope','Uchenna','Victoria','Yetunde','Zainab',
 'Abdullahi','Blessing','Chukwuma','Divine','Ebuka','Fatima','Gbenga','Hauwa','Ikenna','Joy',
 'Kemi','Lukman','Mariam','Nnamdi','Olamide','Peace','Rotimi','Somto','Tobi','Yusuf']);
CREATE TEMP TABLE last_names(n text[]);
INSERT INTO last_names VALUES (ARRAY[
 'Adeyemi','Okafor','Ibrahim','Okonkwo','Bello','Eze','Ogunleye','Nwosu','Abubakar','Adeleke',
 'Chukwu','Danjuma','Ekwueme','Fashola','Gambo','Idowu','Johnson','Kalu','Lawal','Mohammed',
 'Nnaji','Obi','Ojo','Peters','Quadri','Salami','Taiwo','Uche','Usman','Williams',
 'Yakubu','Zubairu','Akinola','Balogun','Coker','Dike','Egwu','Falana','Igwe','Opoola']);
-- lecturers
INSERT INTO lecturer (staff_no, department_id, title, first_name, last_name, email, academic_rank, hire_date)
SELECT 'SP/' || lpad(g::text, 5, '0'),
       d.department_id,
       (ARRAY['Mr','Mrs','Dr','Dr','Dr','Prof'])[1 + (g % 6)],
       fn, ln,
       lower(fn || '.' || ln || g) || '@aurelia.edu.ng',
       (ARRAY['Assistant Lecturer','Lecturer II','Lecturer I','Senior Lecturer','Associate Professor','Professor'])[1 + (g % 6)],
       DATE '2005-01-01' + (random() * 6500)::int
FROM generate_series(1, 180) AS g
JOIN department d ON d.department_id = 1 + ((g - 1) / 15)
CROSS JOIN LATERAL (
    SELECT (SELECT n FROM first_names)[1 + floor(random() * 50)::int + 0 * g] AS fn,
           (SELECT n FROM last_names)[1 + floor(random() * 40)::int + 0 * g]  AS ln
) names;
-- courses: 12 per department per level
INSERT INTO course (course_code, title, department_id, credit_units, level, term)
SELECT d.code || lv || lpad(n::text, 2, '0'),
       (ARRAY['Foundations of','Principles of','Methods in','Laboratory Practice in',
              'Mathematics for','Communication in','Theory of','Applied',
              'Computational Methods in','Systems in','Seminar in','Project Studies in'])[n]
         || ' ' || d.name || ' ' || (ARRAY['I','II','III','IV'])[lv],
       d.department_id,
       (ARRAY[2,3,4])[1 + (n % 3)],
       lv * 100,
       CASE WHEN n <= 6 THEN 'FIRST' ELSE 'SECOND' END
FROM department d
CROSS JOIN generate_series(1, 4)  AS lv
CROSS JOIN generate_series(1, 12) AS n;

-- XXX2nn requires XXX1nn, etc.
INSERT INTO course_prerequisite (course_id, prereq_course_id)
SELECT c.course_id, p.course_id
FROM course c
JOIN course p ON p.department_id = c.department_id
             AND p.level = c.level - 100
             AND right(p.course_code, 2) = right(c.course_code, 2)
WHERE c.level >= 200;
-- offerings
INSERT INTO course_offering (course_id, semester_id, lecturer_id, capacity)
SELECT c.course_id, s.semester_id, l.lecturer_id, 1000
FROM course c
JOIN semester s ON s.term = c.term
CROSS JOIN LATERAL (
    SELECT lecturer_id FROM lecturer
    WHERE department_id = c.department_id
    ORDER BY random() + 0 * s.semester_id
    LIMIT 1
) l;
-- students
INSERT INTO student (matric_no, programme_id, first_name, last_name, gender, date_of_birth,
                     email, entry_year, current_level, status, created_at)
SELECT 'AU/' || ey || '/' || lpad(g::text, 5, '0'),
       1 + floor(random() * 12)::int,
       fn, ln,
       CASE WHEN random() < 0.48 THEN 'F' ELSE 'M' END,
       make_date(ey - 17, 1, 1) - (random() * 1800)::int,
       lower(fn || '.' || ln || '.' || g) || '@students.aurelia.edu.ng',
       ey,
       LEAST(400, (2026 - ey + 1) * 100),
       CASE WHEN ey <= 2022 THEN 'GRADUATED' ELSE 'ACTIVE' END,
       make_timestamptz(ey, 9, 1, 9, 0, 0)
FROM (SELECT g, 2021 + (g % 6) AS ey FROM generate_series(1, 20000) g) x
CROSS JOIN LATERAL (
    SELECT (SELECT n FROM first_names)[1 + floor(random() * 50)::int + 0 * g] AS fn,
           (SELECT n FROM last_names)[1 + floor(random() * 40)::int + 0 * g]  AS ln
) names;

CREATE TEMP TABLE student_ability AS
SELECT student_id, 60 + 11 * pg_temp.rnorm() AS ability FROM student;
-- past results
INSERT INTO enrollment (student_id, offering_id, registered_at, status,
                        ca_score, exam_score, result_status, graded_at)
SELECT st.student_id,
       o.offering_id,
       sem.start_date + (random() * 14)::int,
       'COMPLETED',
       LEAST(30, GREATEST(0, round((0.30 * perf + 1.5 * pg_temp.rnorm())::numeric, 0))),
       LEAST(70, GREATEST(0, round((0.70 * perf + 4.0 * pg_temp.rnorm())::numeric, 0))),
       'APPROVED',
       sem.end_date + 21
FROM student st
JOIN student_ability sa USING (student_id)
JOIN programme p        ON p.programme_id = st.programme_id
JOIN semester sem       ON TRUE
JOIN academic_session ses ON ses.session_id = sem.session_id
JOIN course c           ON c.department_id = p.department_id
                       AND c.term  = sem.term
                       AND c.level = (substr(ses.name,1,4)::int - st.entry_year + 1) * 100
JOIN course_offering o  ON o.course_id = c.course_id AND o.semester_id = sem.semester_id
CROSS JOIN LATERAL (SELECT sa.ability + 9 * pg_temp.rnorm() + 0 * o.offering_id AS perf) pf
WHERE substr(ses.name,1,4)::int BETWEEN st.entry_year AND st.entry_year + 3
  AND sem.results_published;
-- current semester: registered, no scores yet
INSERT INTO enrollment (student_id, offering_id, registered_at, status, result_status)
SELECT st.student_id, o.offering_id,
       sem.start_date + (random() * 10)::int, 'REGISTERED', 'PENDING'
FROM student st
JOIN programme p  ON p.programme_id = st.programme_id
JOIN semester sem ON sem.registration_open
JOIN course c     ON c.department_id = p.department_id
                 AND c.term = sem.term
                 AND c.level = st.current_level
                 AND right(c.course_code, 2)::int <= 4
JOIN course_offering o ON o.course_id = c.course_id AND o.semester_id = sem.semester_id
WHERE st.status = 'ACTIVE';

UPDATE course_offering o
SET seats_taken = x.cnt
FROM (SELECT offering_id, count(*) AS cnt FROM enrollment
      WHERE status <> 'DROPPED' GROUP BY offering_id) x
WHERE x.offering_id = o.offering_id;

UPDATE course_offering SET capacity = seats_taken + 25;

-- probation (CGPA < 1.50)
UPDATE student s SET status = 'PROBATION'
FROM (
    SELECT e.student_id,
           sum(g.grade_point * c.credit_units) / sum(c.credit_units) AS cgpa
    FROM enrollment e
    JOIN course_offering o ON o.offering_id = e.offering_id
    JOIN course c          ON c.course_id   = o.course_id
    JOIN grade_scale g     ON g.score_range @> e.total_score
    WHERE e.status = 'COMPLETED'
    GROUP BY e.student_id
) r
WHERE r.student_id = s.student_id AND s.status = 'ACTIVE' AND r.cgpa < 1.5;

ANALYZE;
