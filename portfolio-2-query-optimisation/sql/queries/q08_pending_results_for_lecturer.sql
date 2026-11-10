-- Q08 Grade-entry screen: pending results for every course lecturer SP/00001 teaches
SELECT c.course_code, s.matric_no, e.ca_score, e.exam_score
FROM course_offering o
JOIN course c     ON c.course_id    = o.course_id
JOIN enrollment e ON e.offering_id  = o.offering_id
JOIN student s    ON s.student_id   = e.student_id
WHERE o.lecturer_id = (SELECT lecturer_id FROM lecturer WHERE staff_no = 'SP/00001')
  AND e.result_status = 'PENDING'
ORDER BY c.course_code, s.matric_no;
