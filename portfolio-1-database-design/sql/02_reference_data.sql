-- reference data

INSERT INTO faculty (code, name) VALUES
 ('FCI',  'Faculty of Computing and Informatics'),
 ('FMS',  'Faculty of Management Sciences'),
 ('FNAS', 'Faculty of Natural and Applied Sciences'),
 ('FEN',  'Faculty of Engineering');

INSERT INTO department (faculty_id, code, name)
SELECT f.faculty_id, d.code, d.name
FROM (VALUES
  ('FCI', 'CSC','Computer Science'),
  ('FCI', 'CYB','Cybersecurity'),
  ('FCI', 'SEN','Software Engineering'),
  ('FCI', 'IFT','Information Technology'),
  ('FMS', 'ACC','Accounting'),
  ('FMS', 'BUS','Business Administration'),
  ('FMS', 'ECO','Economics'),
  ('FNAS','MTH','Mathematics'),
  ('FNAS','PHY','Physics'),
  ('FNAS','MCB','Microbiology'),
  ('FEN', 'EEE','Electrical and Electronics Engineering'),
  ('FEN', 'MEE','Mechanical Engineering')
) AS d(fac, code, name)
JOIN faculty f ON f.code = d.fac;

INSERT INTO programme (department_id, code, name, award, duration_years)
SELECT d.department_id,
       'B-' || d.code,
       CASE WHEN f.code = 'FEN' THEN 'B.Eng. ' ELSE 'B.Sc. ' END || d.name,
       CASE WHEN f.code = 'FEN' THEN 'BEng'    ELSE 'BSc'    END,
       4
FROM department d JOIN faculty f USING (faculty_id);

-- half-open ranges, except A which includes 100
INSERT INTO grade_scale (grade_letter, score_range, grade_point, remark) VALUES
 ('A', '[70,100]', 5.0, 'Excellent'),
 ('B', '[60,70)',  4.0, 'Very Good'),
 ('C', '[50,60)',  3.0, 'Good'),
 ('D', '[45,50)',  2.0, 'Fair'),
 ('E', '[40,45)',  1.0, 'Pass'),
 ('F', '[0,40)',   0.0, 'Fail');

INSERT INTO academic_session (name, start_date, end_date)
SELECT y || '/' || (y + 1), make_date(y, 9, 15), make_date(y + 1, 8, 31)
FROM generate_series(2021, 2026) AS y;

INSERT INTO semester (session_id, term, start_date, end_date, registration_open, results_published)
SELECT s.session_id, t.term,
       CASE t.term WHEN 'FIRST' THEN s.start_date ELSE make_date(extract(year FROM s.end_date)::int, 2, 1) END,
       CASE t.term WHEN 'FIRST' THEN make_date(extract(year FROM s.end_date)::int, 1, 20) ELSE s.end_date END,
       (s.name = '2026/2027' AND t.term = 'FIRST'),
       NOT (s.name = '2026/2027')
FROM academic_session s
CROSS JOIN (VALUES ('FIRST'), ('SECOND')) AS t(term)
ORDER BY s.session_id, t.term;
