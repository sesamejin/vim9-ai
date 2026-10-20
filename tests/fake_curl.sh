#!/bin/sh
# Fake curl used by the test suite: answers with a canned SSE stream.
# It ignores the request and only honours `--dump-header`.

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

printf 'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n'
printf 'data: {"choices":[{"delta":{"content":" world"}}]}\n\n'
printf 'data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}\n\n'
printf 'data: {"choices":[{"delta":{"content":"\\nSecond line"}}]}\n\n'
printf 'data: [DONE]\n\n'
exit 0
