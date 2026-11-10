-- Q05 Senate report: pass rate and mean score of every Computing course in 2025/2026
SELECT c.course_code, sem.term,
       count(*) AS candidates,
       round(avg(e.total_score), 1) AS mean_score,
       round(100.0 * count(*) FILTER (WHERE e.total_score >= 40) / count(*), 1) AS pass_rate_pct
FROM academic_session ses
JOIN semester sem      ON sem.session_id = ses.session_id
JOIN course_offering o ON o.semester_id  = sem.semester_id
JOIN course c          ON c.course_id    = o.course_id
JOIN department d      ON d.department_id = c.department_id
JOIN enrollment e      ON e.offering_id  = o.offering_id
WHERE ses.name = '2025/2026' AND d.code IN ('CSC','CYB','SEN','IFT') AND e.status = 'COMPLETED'
GROUP BY c.course_code, sem.term
ORDER BY pass_rate_pct, c.course_code;
