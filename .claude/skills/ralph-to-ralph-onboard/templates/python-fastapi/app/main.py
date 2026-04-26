from fastapi import FastAPI

app = FastAPI(title="Ralph Python FastAPI Template")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}
