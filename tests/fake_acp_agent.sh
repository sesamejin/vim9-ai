#!/bin/sh
# Fake ACP agent used by the test suite.
#
# It speaks newline delimited JSON-RPC 2.0 on stdin and stdout, enough of the
# protocol to exercise the client. What happens on `session/prompt` depends on
# the text of the prompt:
#   hang       - no answer at all, only `session/cancel` ends the turn
#   permission - asks `session/request_permission` before answering
#   readfile   - asks the client for the file given as $1
#   writefile  - asks the client to write the file given as $2
#   anything   - a thought, a tool call and two message chunks
#
# The client is started with the paths as arguments, they have to use forward
# slashes because they end up inside json.

read_path="$1"
write_path="$2"
prompt_id=""

send() {
  printf '%s\n' "$1"
}

extract_id() {
  printf '%s\n' "$1" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

extract_method() {
  printf '%s\n' "$1" | sed -n 's/.*"method"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

extract_text() {
  printf '%s\n' "$1" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

extract_option() {
  printf '%s\n' "$1" | sed -n 's/.*"optionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

chunk() {
  send "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess_fake\",\"update\":{\"sessionUpdate\":\"$1\",\"content\":{\"type\":\"text\",\"text\":\"$2\"}}}}"
}

answer() {
  answer_id="$1"
  chunk agent_message_chunk "echo:$(extract_text "$line")"
  chunk agent_thought_chunk "thinking"
  send '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_fake","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"Read file","kind":"read","status":"pending"}}}'
  chunk agent_message_chunk "Hello"
  chunk agent_message_chunk " world"
  send "{\"jsonrpc\":\"2.0\",\"id\":$answer_id,\"result\":{\"stopReason\":\"end_turn\"}}"
  prompt_id=""
}

while IFS= read -r line; do
  method=$(extract_method "$line")
  id=$(extract_id "$line")

  # a response to one of the requests the agent made
  if [ -z "$method" ]; then
    case "$id" in
      900)
        chunk agent_message_chunk "permission: $(extract_option "$line")"
        send "{\"jsonrpc\":\"2.0\",\"id\":$prompt_id,\"result\":{\"stopReason\":\"end_turn\"}}"
        prompt_id=""
        ;;
      800)
        if printf '%s\n' "$line" | grep -q "FAKE_ACP_MARKER"; then
          chunk agent_message_chunk "read: found"
        else
          chunk agent_message_chunk "read: missing"
        fi
        send "{\"jsonrpc\":\"2.0\",\"id\":$prompt_id,\"result\":{\"stopReason\":\"end_turn\"}}"
        prompt_id=""
        ;;
      801)
        chunk agent_message_chunk "wrote"
        send "{\"jsonrpc\":\"2.0\",\"id\":$prompt_id,\"result\":{\"stopReason\":\"end_turn\"}}"
        prompt_id=""
        ;;
    esac
    continue
  fi

  case "$method" in
    initialize)
      send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":false,\"promptCapabilities\":{\"image\":true,\"audio\":false,\"embeddedContext\":true}},\"agentInfo\":{\"name\":\"fake-acp-agent\",\"title\":\"Fake ACP agent\",\"version\":\"1.0\"},\"authMethods\":[]}}"
      ;;
    session/new)
      send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"sess_fake\"}}"
      ;;
    session/prompt)
      prompt_id="$id"
      case "$line" in
        *hang*)
          # no answer, the client has to send `session/cancel`
          ;;
        *permission*)
          send '{"jsonrpc":"2.0","id":900,"method":"session/request_permission","params":{"sessionId":"sess_fake","toolCall":{"toolCallId":"call_1","title":"Run a command"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}}'
          ;;
        *readfile*)
          send "{\"jsonrpc\":\"2.0\",\"id\":800,\"method\":\"fs/read_text_file\",\"params\":{\"sessionId\":\"sess_fake\",\"path\":\"$read_path\"}}"
          ;;
        *writefile*)
          send "{\"jsonrpc\":\"2.0\",\"id\":801,\"method\":\"fs/write_text_file\",\"params\":{\"sessionId\":\"sess_fake\",\"path\":\"$write_path\",\"content\":\"written by the agent\"}}"
          ;;
        *)
          answer "$id"
          ;;
      esac
      ;;
    session/cancel)
      if [ -n "$prompt_id" ]; then
        send "{\"jsonrpc\":\"2.0\",\"id\":$prompt_id,\"result\":{\"stopReason\":\"cancelled\"}}"
        prompt_id=""
      fi
      ;;
  esac
done
