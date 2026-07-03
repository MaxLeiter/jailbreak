#!/usr/bin/env bash
# Publish the low-cache staging repo (dev.repo.maxleiter.com).
exec "$(dirname "${BASH_SOURCE[0]}")/publish-repo.sh" --staging "$@"
