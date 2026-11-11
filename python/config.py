"""Спільні налаштування. Усе можна перевизначити змінними середовища."""
import os

PG_DSN = os.getenv("PG_DSN", "postgresql://postgres:postgres@localhost:55432/lms")
MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:57017")
MONGO_DB = os.getenv("MONGO_DB", "lms_bench")
MONGO_COLLECTION = "course_versions"
NEO4J_URI = os.getenv("NEO4J_URI", "bolt://localhost:57687")
NEO4J_AUTH = (os.getenv("NEO4J_USER", "neo4j"), os.getenv("NEO4J_PASSWORD", "password123"))

SEED = int(os.getenv("BENCH_SEED", "42"))
BENCH_PREFIX = "BENCH-"           # усі згенеровані курси мають такий префікс коду
ACTOR_ID = 1                      # адміністратор із 07_seed.sql
RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
