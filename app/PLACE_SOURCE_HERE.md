# Place OpenShorts source here

Before building the Docker image, copy your OpenShorts repo into this `app/` folder
(dashboard is optional — the image does not serve it).

```bash
# from openshorts-runpod/
./scripts/sync-app.sh /path/to/openshorts
```

Expected layout after sync:

```
app/
  app.py          # or package that uvicorn can load as app:app
  requirements.txt
  requirements-billing.txt   # optional
  remotion/
  render-service/
  ...
```

The container entrypoint runs:

```
python -m uvicorn app:app --host 127.0.0.1 --port 8000
```

inside `/app`, same as your pod script.
