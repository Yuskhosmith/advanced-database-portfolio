-- Q01 Student transcript: every result of one student (portal "My Results" page)
SELECT ses.name AS session, sem.term, c.course_code, c.title, c.credit_units AS cu,
       e.total_score AS total, g.grade_letter AS grade, g.grade_point AS gp
FROM student s
JOIN enrollment e          ON e.student_id    = s.student_id
JOIN course_offering o     ON o.offering_id   = e.offering_id
JOIN course c              ON c.course_id     = o.course_id
JOIN semester sem          ON sem.semester_id = o.semester_id
JOIN academic_session ses  ON ses.session_id  = sem.session_id
LEFT JOIN grade_scale g    ON g.score_range @> e.total_score
WHERE s.matric_no = 'AU/2022/00007'
ORDER BY sem.semester_id, c.course_code;
