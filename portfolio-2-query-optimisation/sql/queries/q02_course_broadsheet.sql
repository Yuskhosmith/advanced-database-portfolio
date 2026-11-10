-- Q02 Course broadsheet: all students and scores for CSC301 in 2025/2026 (lecturer/exam officer view)
SELECT s.matric_no, s.last_name || ', ' || s.first_name AS student,
       e.ca_score AS ca, e.exam_score AS exam, e.total_score AS total, g.grade_letter AS grade
FROM course c
JOIN course_offering o    ON o.course_id    = c.course_id
JOIN semester sem         ON sem.semester_id = o.semester_id
JOIN academic_session ses ON ses.session_id = sem.session_id
JOIN enrollment e         ON e.offering_id  = o.offering_id
JOIN student s            ON s.student_id   = e.student_id
LEFT JOIN grade_scale g   ON g.score_range @> e.total_score
WHERE c.course_code = 'CSC301' AND ses.name = '2025/2026'
ORDER BY s.matric_no;
