-- Q03 (optimised) Dean's list read from the pre-aggregated materialized view mv_student_cgpa
SELECT dept, rnk, matric_no, student, cgpa FROM (
    SELECT m.dept_code AS dept, m.matric_no, m.student_name AS student, m.cgpa,
           dense_rank() OVER (PARTITION BY m.department_id ORDER BY m.cgpa DESC) AS rnk
    FROM mv_student_cgpa m
    WHERE m.status = 'ACTIVE'
) r
WHERE rnk <= 3 ORDER BY dept, rnk, matric_no;
