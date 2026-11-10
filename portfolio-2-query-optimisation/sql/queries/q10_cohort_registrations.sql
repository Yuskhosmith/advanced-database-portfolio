-- Q10 Registrations of the 2024 cohort currently in 300 level, per course
--     (entry_year and current_level are correlated: planner row estimates suffer)
SELECT c.course_code, count(*) AS registered
FROM student s
JOIN enrollment e      ON e.student_id = s.student_id
JOIN course_offering o ON o.offering_id = e.offering_id
JOIN course c          ON c.course_id = o.course_id
WHERE s.entry_year = 2024 AND s.current_level = 300 AND e.status = 'REGISTERED'
GROUP BY c.course_code
ORDER BY c.course_code;
