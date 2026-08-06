---
title: Rossmann Demand Forecast Wrapper
sdk: docker
app_port: 7860
---

This is a minimal Hugging Face Space wrapper repo.

It contains only:
- Dockerfile
- README.md
- .gitignore

How it works:
- The Dockerfile clones the source project from GitHub at build time.
- It is pinned to an exact commit hash, so each rebuild uses the same code version.
- It installs the source requirements.
- It runs the source entrypoint at docker/entrypoint.huggingface.sh.

Build args you can override:
- SOURCE_REPO_URL (default: https://github.com/benkeddad/mlops-demand-forecast.git)
- SOURCE_COMMIT (default: 5e8a709402beafd1238881c581f441a3171a3216)

Push this wrapper repo to your HF Space:

git init
git add .
git commit -m "Initial HF wrapper"
git branch -M main
git remote add origin https://huggingface.co/spaces/benkeddad/rossmann-demand-forecast
git push -u origin main

When prompted:
- Username: your Hugging Face username
- Password: your Hugging Face write token
