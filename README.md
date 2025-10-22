# deploy.sh — Automated Docker deployment to a remote Linux server

## Purpose
This repository contains `deploy.sh`, a Bash script that automates cloning a Git repository, preparing a remote Linux host (Docker, docker-compose, Nginx), transferring the project, starting the container(s), and configuring Nginx as a reverse proxy.

## Quick start
1. Make the script executable:
```bash
chmod +x deploy.sh
