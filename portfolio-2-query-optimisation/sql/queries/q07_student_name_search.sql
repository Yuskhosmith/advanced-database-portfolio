-- Q07 Registry search box: case-insensitive prefix search on surname
SELECT matric_no, first_name, last_name, current_level, status
FROM student
WHERE lower(last_name) LIKE 'okon%' AND lower(first_name) LIKE 'chi%'
ORDER BY matric_no;
