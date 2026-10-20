#!/bin/sh
# Fake curl used by the test suite: answers with a base64 encoded 1x1 png.

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

printf '{"data":[{"b64_json":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGNgAAACAAEABf4C/qc1AAAAAElFTkSuQmCC"}]}'
exit 0
