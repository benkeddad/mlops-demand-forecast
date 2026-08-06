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
- It installs the source requirements.
- It runs the source entrypoint at docker/entrypoint.huggingface.sh.

Build args you can override:
- SOURCE_REPO_URL (default: https://github.com/benkeddad/mlops-demand-forecast.git)
- SOURCE_REF (default: main)

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
