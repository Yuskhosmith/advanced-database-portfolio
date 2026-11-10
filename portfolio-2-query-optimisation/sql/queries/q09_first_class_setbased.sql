-- Q09b First-class candidates in Computer Science - SET-BASED rewrite (one join + GROUP BY)
SELECT s.matric_no, s.first_name || ' ' || s.last_name AS student,
       round(sum(g.grade_point * c.credit_units) / sum(c.credit_units), 2) AS cgpa
FROM student s
JOIN programme p       ON p.programme_id = s.programme_id
JOIN department d      ON d.department_id = p.department_id
JOIN enrollment e      ON e.student_id = s.student_id
JOIN course_offering o ON o.offering_id = e.offering_id
JOIN course c          ON c.course_id = o.course_id
JOIN grade_scale g     ON g.score_range @> e.total_score
WHERE d.code = 'CSC' AND e.status = 'COMPLETED' AND e.result_status = 'APPROVED'
GROUP BY s.student_id, s.matric_no, s.first_name, s.last_name
HAVING round(sum(g.grade_point * c.credit_units) / sum(c.credit_units), 2) >= 4.5
ORDER BY cgpa DESC, s.matric_no;
