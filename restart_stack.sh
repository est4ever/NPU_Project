#!/usr/bin/env bash
# HPC: restart backend only (no browser app shell on compute nodes).
exec "$(dirname "$0")/restart_backend.sh"
