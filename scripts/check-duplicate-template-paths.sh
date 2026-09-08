#!/usr/bin/env bash
# Fails if any two .yaml files directly under a given directory declare the
# same `path:` value. Usage:
#   scripts/check-duplicate-template-paths.sh <template-dir> [<template-dir> ...]
set -euo pipefail

status=0

for dir in "$@"; do
  if [ ! -d "$dir" ]; then
    echo "error: directory not found: $dir" >&2
    exit 1
  fi

  pairs=$(grep -H "^path:" "$dir"/*.yaml 2>/dev/null | sed -E 's/^([^:]+):path:[[:space:]]*/\1\t/' || true)
  if [ -z "$pairs" ]; then
    continue
  fi

  dupes=$(printf '%s\n' "$pairs" | awk -F'\t' '{print $2}' | sort | uniq -d)
  if [ -n "$dupes" ]; then
    echo "duplicate path: declarations found in $dir:" >&2
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      echo "  path: $p" >&2
      printf '%s\n' "$pairs" | awk -F'\t' -v p="$p" '$2==p {print "    - " $1}' >&2
    done <<< "$dupes"
    status=1
  fi
done

exit $status
