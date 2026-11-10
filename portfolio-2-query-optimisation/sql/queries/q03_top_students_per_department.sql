-- Q03 Dean's list: top 3 active students per department by CGPA (computed on the fly)
WITH cgpa AS (
    SELECT e.student_id,
           round(sum(g.grade_point * c.credit_units) / sum(c.credit_units), 2) AS cgpa
    FROM enrollment e
    JOIN course_offering o ON o.offering_id = e.offering_id
    JOIN course c          ON c.course_id   = o.course_id
    JOIN grade_scale g     ON g.score_range @> e.total_score
    WHERE e.status = 'COMPLETED' AND e.result_status = 'APPROVED'
    GROUP BY e.student_id
), ranked AS (
    SELECT d.code AS dept, s.matric_no, s.first_name || ' ' || s.last_name AS student, x.cgpa,
           dense_rank() OVER (PARTITION BY d.department_id ORDER BY x.cgpa DESC) AS rnk
    FROM cgpa x
    JOIN student s    ON s.student_id = x.student_id
    JOIN programme p  ON p.programme_id = s.programme_id
    JOIN department d ON d.department_id = p.department_id
    WHERE s.status = 'ACTIVE'
)
SELECT dept, rnk, matric_no, student, cgpa FROM ranked WHERE rnk <= 3 ORDER BY dept, rnk, matric_no;
