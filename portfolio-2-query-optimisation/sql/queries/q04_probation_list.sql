-- Q04 Probation list: Computer Science students whose CGPA is below 1.50
SELECT s.matric_no, s.first_name || ' ' || s.last_name AS student, s.current_level,
       round(sum(g.grade_point * c.credit_units) / sum(c.credit_units), 2) AS cgpa
FROM department d
JOIN programme p       ON p.department_id = d.department_id
JOIN student s         ON s.programme_id  = p.programme_id
JOIN enrollment e      ON e.student_id    = s.student_id
JOIN course_offering o ON o.offering_id   = e.offering_id
JOIN course c          ON c.course_id     = o.course_id
JOIN grade_scale g     ON g.score_range @> e.total_score
WHERE d.code = 'CSC' AND s.status IN ('ACTIVE','PROBATION') AND e.status = 'COMPLETED'
GROUP BY s.student_id, s.matric_no, s.first_name, s.last_name, s.current_level
HAVING sum(g.grade_point * c.credit_units) / sum(c.credit_units) < 1.5
ORDER BY cgpa;
