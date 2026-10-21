#!/bin/sh
# Fake curl used by the test suite: emits two chunks and then stalls, so that
# cancelling a running chat job can be exercised. `exec` keeps the process
# replaceable, which lets job_stop() terminate it right away.

header_file=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "--dump-header" ]; then
    header_file="$argument"
  fi
  previous="$argument"
done

if [ -n "$header_file" ]; then
  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n' > "$header_file"
fi

printf 'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'
printf 'data: {"choices":[{"delta":{"content":" answer"}}]}\n\n'

exec sleep 30
