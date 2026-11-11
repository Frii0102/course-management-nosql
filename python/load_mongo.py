#!/usr/bin/env python3
"""Завантаження опублікованих версій курсів з PostgreSQL у MongoDB.

Документи будуються з ТИХ САМИХ таблиць версій, що й у SQL-частині, тож обидві
бази містять тотожні дані. Колекція створюється з $jsonSchema-валідацією
(аналог CHECK/NOT NULL у SQL), інакше порівнювалися б різні гарантії.
"""
import argparse
import time

import psycopg
from pymongo import ASCENDING, MongoClient

from common import FLAT_VERSION_SQL, assemble, build_document
from config import MONGO_COLLECTION, MONGO_DB, MONGO_URI, PG_DSN

INT = ["int", "long"]

VALIDATOR = {"$jsonSchema": {
    "bsonType": "object",
    "required": ["_id", "courseId", "version", "publishedAt", "publishedBy",
                 "lessonCount", "totalMaxScore", "modules"],
    "properties": {
        "_id": {"bsonType": INT},
        "courseId": {"bsonType": INT},
        "version": {"bsonType": INT, "minimum": 1},
        "publishedAt": {"bsonType": "date"},
        "publishedBy": {"bsonType": INT},
        "lessonCount": {"bsonType": INT, "minimum": 0},
        "totalMaxScore": {"bsonType": ["double", "int", "long"], "minimum": 0},
        "modules": {"bsonType": "array", "items": {
            "bsonType": "object",
            "required": ["moduleId", "position", "title", "lessons"],
            "properties": {
                "position": {"bsonType": INT, "minimum": 1},
                "title": {"bsonType": "string", "minLength": 1},
                "lessons": {"bsonType": "array", "items": {
                    "bsonType": "object",
                    "required": ["lessonId", "title", "content", "durationMinutes",
                                 "position", "materials"],
                    "properties": {
                        "durationMinutes": {"bsonType": INT, "minimum": 1},
                        "position": {"bsonType": INT, "minimum": 1},
                        "materials": {"bsonType": "array", "items": {
                            "bsonType": "object",
                            "required": ["title", "url", "kind"],
                            "properties": {
                                "url": {"bsonType": "string", "pattern": "^https?://"},
                                "kind": {"enum": ["document", "video", "link"]},
                            }}},
                        "assignment": {"bsonType": ["object", "null"]},
                    }}},
            }}},
    },
}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", type=int, default=500)
    ap.add_argument("--drop", action="store_true", help="видалити колекцію перед завантаженням")
    a = ap.parse_args()

    mongo = MongoClient(MONGO_URI)
    db = mongo[MONGO_DB]
    if a.drop and MONGO_COLLECTION in db.list_collection_names():
        db.drop_collection(MONGO_COLLECTION)
    if MONGO_COLLECTION not in db.list_collection_names():
        db.create_collection(MONGO_COLLECTION, validator=VALIDATOR, validationLevel="strict")
    col = db[MONGO_COLLECTION]
    col.create_index([("courseId", ASCENDING), ("version", ASCENDING)], unique=True,
                     name="uq_course_version")
    if col.estimated_document_count() > 0:
        raise SystemExit("Колекція не порожня. Запусти з --drop.")

    pg = psycopg.connect(PG_DSN, autocommit=True)
    meta = pg.execute("""SELECT id, course_id, version, published_at, published_by
                         FROM lms.course_versions ORDER BY id""").fetchall()
    print(f"Версій у PostgreSQL: {len(meta)}", flush=True)
    t0, batch, done = time.perf_counter(), [], 0
    for cv_id, course_id, version, published_at, published_by in meta:
        modules = assemble(pg.execute(FLAT_VERSION_SQL, (cv_id,)).fetchall())
        batch.append(build_document(cv_id, course_id, version, published_at, published_by, modules))
        if len(batch) >= a.batch:
            col.insert_many(batch, ordered=False)
            done += len(batch)
            batch = []
            print(f"  {done}/{len(meta)} ({time.perf_counter() - t0:.0f} с)", flush=True)
    if batch:
        col.insert_many(batch, ordered=False)
        done += len(batch)
    print(f"Завантажено {done} документів за {time.perf_counter() - t0:.0f} с")
    print(f"Перевірка: PostgreSQL={len(meta)}, MongoDB={col.count_documents({})}")


if __name__ == "__main__":
    main()
