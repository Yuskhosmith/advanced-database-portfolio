-- Q06 Lecturer workload in the current (open) semester, incl. results still to be entered
SELECT l.staff_no, l.title || ' ' || l.last_name AS lecturer,
       count(DISTINCT o.offering_id) AS courses,
       count(e.enrollment_id)        AS students,
       count(e.enrollment_id) FILTER (WHERE e.result_status = 'PENDING') AS pending_results
FROM semester sem
JOIN course_offering o ON o.semester_id = sem.semester_id
JOIN lecturer l        ON l.lecturer_id = o.lecturer_id
LEFT JOIN enrollment e ON e.offering_id = o.offering_id AND e.status <> 'DROPPED'
WHERE sem.registration_open
GROUP BY l.lecturer_id, l.staff_no, l.title, l.last_name
ORDER BY students DESC
LIMIT 10;
