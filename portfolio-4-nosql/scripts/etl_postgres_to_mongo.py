#!/usr/bin/env python3
"""Load the students, courses and portal_sessions collections from PostgreSQL."""
import os
import time
from collections import defaultdict
from decimal import Decimal

import psycopg
from pymongo import MongoClient

PG_DSN = (f"dbname={os.environ.get('PGDATABASE', 'university_portal')} "
          f"host={os.environ.get('PGHOST', 'localhost')} port={os.environ.get('PGPORT', '5432')}")
MONGO_URI = os.environ.get("MONGO_URI", "mongodb://127.0.0.1:27117")

def f(x):
    """Decimal -> float for BSON."""
    return float(x) if isinstance(x, Decimal) else x

STUDENT_SCHEMA = {
    "$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "student_id", "name", "programme", "department", "entry_year", "level", "status", "semesters"],
        "properties": {
            "_id": {"bsonType": "string", "pattern": "^AU/[0-9]{4}/[0-9]{5}$", "description": "matric number"},
            "student_id": {"bsonType": "int"},
            "name": {"bsonType": "object", "required": ["first", "last"]},
            "gender": {"enum": ["M", "F"]},
            "level": {"enum": [100, 200, 300, 400, 500, 600]},
            "status": {"enum": ["ACTIVE", "PROBATION", "GRADUATED", "WITHDRAWN", "SUSPENDED"]},
            "semesters": {
                "bsonType": "array",
                "items": {
                    "bsonType": "object",
                    "required": ["session", "term", "courses"],
                    "properties": {
                        "term": {"enum": ["FIRST", "SECOND"]},
                        "gpa": {"bsonType": ["double", "null"], "minimum": 0, "maximum": 5},
                        "courses": {
                            "bsonType": "array",
                            "items": {
                                "bsonType": "object",
                                "required": ["code", "units"],
                                "properties": {
                                    "units": {"bsonType": "int", "minimum": 1, "maximum": 6},
                                    "ca": {"bsonType": ["double", "null"], "minimum": 0, "maximum": 30},
                                    "exam": {"bsonType": ["double", "null"], "minimum": 0, "maximum": 70},
                                    "grade": {"enum": ["A", "B", "C", "D", "E", "F", None]},
                                },
                            },
                        },
                    },
                },
            },
            "summary": {
                "bsonType": "object",
                "properties": {"cgpa": {"bsonType": ["double", "null"], "minimum": 0, "maximum": 5}},
            },
        },
    }
}

def degree_class(cgpa):
    if cgpa is None:
        return "No result"
    for limit, name in ((4.5, "First Class"), (3.5, "Second Class Upper"), (2.4, "Second Class Lower"),
                        (1.5, "Third Class"), (1.0, "Pass")):
        if cgpa >= limit:
            return name
    return "Fail"

def course_attributes(faculty, dept, level, n):
    """Polymorphic attributes: each faculty records different facts about a course."""
    if faculty == "FCI":
        return {"lab_hours": 1 + (n % 3), "software": ["Python", "PostgreSQL", "MongoDB", "Linux"][: 1 + n % 4],
                "online_delivery": n % 2 == 0}
    if faculty == "FNAS":
        return {"lab_hours": 2 + (n % 2), "safety_training_required": dept in ("MCB", "PHY"),
                "field_trip": level >= 300 and n % 4 == 0}
    if faculty == "FEN":
        return {"workshop_hours": 2 + (n % 3), "accreditation": "COREN", "design_project": n >= 11}
    return {"case_studies": 2 + (n % 4), "professional_body": {"ACC": "ICAN", "BUS": "CIBN", "ECO": "NES"}[dept]}

def main():
    t0 = time.perf_counter()
    mongo = MongoClient(MONGO_URI)
    db = mongo["ausrp"]
    for name in ("students", "courses", "portal_sessions"):
        db.drop_collection(name)
    db.create_collection("students", validator=STUDENT_SCHEMA, validationLevel="strict", validationAction="error")

    with psycopg.connect(PG_DSN) as pg, pg.cursor() as cur:
        cur.execute("""
            SELECT c.course_code, c.title, c.credit_units, c.level, c.term, d.code, d.name, f.code,
                   coalesce(array_agg(p.course_code ORDER BY p.course_code) FILTER (WHERE p.course_code IS NOT NULL), '{}')
            FROM course c
            JOIN department d USING (department_id) JOIN faculty f USING (faculty_id)
            LEFT JOIN course_prerequisite cp ON cp.course_id = c.course_id
            LEFT JOIN course p ON p.course_id = cp.prereq_course_id
            GROUP BY c.course_id, d.code, d.name, f.code ORDER BY c.course_code""")
        courses = []
        for code, title, units, level, term, dcode, dname, fcode, prereqs in cur.fetchall():
            n = int(code[4:])
            courses.append({"_id": code, "title": title, "units": units, "level": level, "term": term,
                            "department": {"code": dcode, "name": dname}, "faculty": fcode,
                            "prerequisites": list(prereqs),
                            "attributes": course_attributes(fcode, dcode, level, n)})
        db.courses.insert_many(courses)
        cur.execute("""
            SELECT s.student_id, s.matric_no, s.first_name, s.last_name, s.gender, s.date_of_birth, s.email,
                   s.entry_year, s.current_level, s.status, p.code, p.name, p.award, d.code, d.name, f.code, f.name
            FROM student s JOIN programme p USING (programme_id) JOIN department d USING (department_id)
            JOIN faculty f USING (faculty_id) ORDER BY s.student_id""")
        students = {}
        for r in cur.fetchall():
            students[r[0]] = {
                "_id": r[1], "student_id": r[0], "name": {"first": r[2], "last": r[3]}, "gender": r[4],
                "date_of_birth": r[5].isoformat(), "email": r[6], "entry_year": r[7], "level": r[8], "status": r[9],
                "programme": {"code": r[10], "name": r[11], "award": r[12]},
                "department": {"code": r[13], "name": r[14]}, "faculty": {"code": r[15], "name": r[16]},
                "semesters": [],
            }

        cur.execute("""
            SELECT e.student_id, ses.name, sem.term, sem.semester_id, c.course_code, c.title, c.credit_units,
                   e.ca_score, e.exam_score, e.total_score, g.grade_letter, g.grade_point, e.status, e.result_status
            FROM enrollment e
            JOIN course_offering o USING (offering_id) JOIN course c USING (course_id)
            JOIN semester sem USING (semester_id) JOIN academic_session ses USING (session_id)
            LEFT JOIN grade_scale g ON g.score_range @> e.total_score
            WHERE e.status <> 'DROPPED'
            ORDER BY e.student_id, sem.semester_id, c.course_code""")
        sems = defaultdict(dict)
        for (sid, session, term, sem_id, code, title, units, ca, exam, total, grade, gp, status, rstatus) in cur:
            sem = sems[sid].setdefault(sem_id, {"session": session, "term": term, "courses": []})
            sem["courses"].append({"code": code, "title": title, "units": units, "ca": f(ca), "exam": f(exam),
                                   "total": f(total), "grade": grade, "gp": f(gp), "status": status,
                                   "result_status": rstatus})

    docs = []
    for sid, doc in students.items():
        tot_units = tot_qp = passed = 0
        for sem_id in sorted(sems.get(sid, {})):
            sem = sems[sid][sem_id]
            graded = [c for c in sem["courses"] if c["result_status"] == "APPROVED"]
            u = sum(c["units"] for c in graded)
            qp = sum(c["units"] * c["gp"] for c in graded)
            sem["units"] = u
            sem["gpa"] = round(qp / u, 2) if u else None
            tot_units += u
            tot_qp += qp
            passed += sum(c["units"] for c in graded if c["gp"] > 0)
            doc["semesters"].append(sem)
        cgpa = round(tot_qp / tot_units, 2) if tot_units else None
        doc["summary"] = {"cgpa": cgpa, "units_taken": tot_units, "units_passed": passed,
                          "class_of_degree": degree_class(cgpa)}
        docs.append(doc)
    for i in range(0, len(docs), 1000):
        db.students.insert_many(docs[i:i + 1000], ordered=False)
    db.portal_sessions.create_index("expires_at", expireAfterSeconds=0)

    mongo.admin.command("fsync")  # so storageSize is up to date
    stats = {n: db.command("collStats", n) for n in ("students", "courses")}
    print(f"ETL finished in {time.perf_counter() - t0:.1f}s")
    for n, s in stats.items():
        print(f"  {n:<9} documents={s['count']:>6}  avgObjSize={s['avgObjSize']:>6} B  "
              f"dataSize={s['size'] / 1e6:6.1f} MB  storageSize(compressed)={s['storageSize'] / 1e6:6.1f} MB  "
              f"indexes={s['totalIndexSize'] / 1e6:5.1f} MB")

if __name__ == "__main__":
    main()
