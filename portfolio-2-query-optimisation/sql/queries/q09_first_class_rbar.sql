-- Q09a First-class candidates in Computer Science - ROW-BY-ROW: calls fn_cgpa() twice per student
SELECT s.matric_no, s.first_name || ' ' || s.last_name AS student, fn_cgpa(s.student_id) AS cgpa
FROM student s
JOIN programme p ON p.programme_id = s.programme_id
JOIN department d ON d.department_id = p.department_id
WHERE d.code = 'CSC' AND fn_cgpa(s.student_id) >= 4.5
ORDER BY cgpa DESC, s.matric_no;
