#!/bin/sh
# Fake curl used by the test suite: never answers, so that the bounded wait in
# `vim_ai_http#Wait()` can be exercised. `exec` keeps the process replaceable,
# which lets job_stop() terminate it right away.

exec sleep 30
