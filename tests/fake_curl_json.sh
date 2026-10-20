#!/bin/sh
# Fake curl used by the test suite: answers with a non streamed completion.

header_file=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "--dump-header" ]; then
    header_file="$argument"
  fi
  previous="$argument"
done

if [ -n "$header_file" ]; then
  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n' > "$header_file"
fi

printf '{"choices":[{"message":{"content":"Hello world\\nSecond line"}}]}'
exit 0
