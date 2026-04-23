# --- python-fastapi targets (appended by onboarding) ---

check:
	python -m ruff check app tests

test:
	python -m pytest

dev:
	python -m uvicorn app.main:app --host 0.0.0.0 --port 3015 --reload

build:
	python - <<'PY'
import app.main
print('build ok')
PY
