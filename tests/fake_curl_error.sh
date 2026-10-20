#!/bin/sh
# Fake curl used by the test suite: answers with an HTTP 401 error.

header_file=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "--dump-header" ]; then
    header_file="$argument"
  fi
  previous="$argument"
done

if [ -n "$header_file" ]; then
  printf 'HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n' > "$header_file"
fi

printf '{"error":{"message":"Incorrect API key provided"}}'
exit 0
