#!/bin/sh
# Fake curl used by the test suite: reports the request headers it received
# through `--config` as the completion text. Proves that the api key travels in
# the config file instead of the command line.

header_file=""
config_file=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "--dump-header" ]; then
    header_file="$argument"
  fi
  if [ "$previous" = "--config" ]; then
    config_file="$argument"
  fi
  previous="$argument"
done

if [ -n "$header_file" ]; then
  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n' > "$header_file"
fi

authorization="missing Authorization header"
if [ -n "$config_file" ] && [ -f "$config_file" ]; then
  line=$(grep -i '^header = "Authorization:' "$config_file")
  if [ -n "$line" ]; then
    authorization=$(printf '%s' "$line" | sed 's/^header = "//; s/"$//')
  fi
fi

printf 'data: {"choices":[{"delta":{"content":"%s"}}]}\n\n' "$authorization"
printf 'data: [DONE]\n\n'
exit 0
