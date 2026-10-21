vim9script

import autoload 'vim_ai_config.vim' as cfg
import autoload 'vim_ai_util.vim' as util

# ACP (Agent Client Protocol) client, see https://agentclientprotocol.com
#
# An ACP agent is a subprocess that speaks JSON-RPC 2.0 over stdin and stdout,
# one message per line. This module owns the agent processes, the sessions, and
# the client side methods an agent may call (`fs/read_text_file`,
# `fs/write_text_file` and `session/request_permission`).
#
# `vim_ai_provider_acp.vim` maps the provider interface onto this module and
# `vim_ai_http.Wait()` drives a turn synchronously, so the callers do not need
# to know whether the response comes from an HTTP stream or from an agent.
#
# A session keeps one agent process alive. Sessions are reused per buffer by
# default: a chat buffer continues the same agent session, therefore only the
# last user message is sent on every turn. `:AI` and `:AIEdit` do not reuse
# sessions, they send the whole conversation as a single prompt and stop the
# agent afterwards.

const protocol_version = 1
# seconds without any message from the agent before the turn is considered
# stalled, 0 disables the check
const default_timeout = 300
# how long the agent gets to answer `session/cancel` before the turn is ended
# by the client
const cancel_grace_ms = 5000

# session key -> session
var sessions: dict<dict<any>> = {}
# makes the key of a one-shot session unique
var serial = 0

# `string()` quotes strings (it is meant for `eval()` round trips), json values
# on the other hand have to be converted without the quotes.
def Text(value: any): string
  return type(value) == v:t_string ? value : string(value)
enddef

# ---------------------------------------------------------------------------
# options
# ---------------------------------------------------------------------------

# Key of the session the request belongs to. A chat buffer has one session, the
# same key is used again on the next turn, which is how a conversation is
# continued by the agent.
export def SessionKey(options: dict<any>): string
  var key = get(options, 'session_key', '')
  if type(key) == v:t_string && trim(key) != ''
    return trim(key)
  endif
  return BufferKey(bufnr('%'))
enddef

export def BufferKey(bufnr: number): string
  return 'buffer:' .. bufnr
enddef

def AllowsReuse(options: dict<any>): bool
  return cfg.Enabled(get(options, 'reuse_session', 0))
enddef

def TimeoutSeconds(options: dict<any>): number
  var value = get(options, 'request_timeout', default_timeout)
  var value_type = type(value)
  if value_type == v:t_string
    return str2nr(value)
  elseif value_type == v:t_float
    return float2nr(value)
  elseif value_type == v:t_number
    return value
  endif
  return default_timeout
enddef

def ProtocolVersion(options: dict<any>): number
  var value = get(options, 'protocol_version', protocol_version)
  return type(value) == v:t_number ? value : str2nr(Text(value))
enddef

def PermissionMode(options: dict<any>): string
  var value = tolower(trim(Text(get(options, 'permission_mode', 'ask'))))
  return index(['ask', 'allow', 'deny'], value) >= 0 ? value : 'ask'
enddef

def AgentCommand(options: dict<any>): list<string>
  var command = get(options, 'agent_command', [])
  var result: list<string> = []
  if type(command) == v:t_list
    for element in command
      result->add(Text(element))
    endfor
  elseif type(command) == v:t_string
    result = split(command)
  endif
  if empty(result)
    util.Throw('acp: `agent_command` is not configured, for example {agent_command: [''claude-code-acp'']}')
  endif
  return result
enddef

def WorkingDirectory(options: dict<any>): string
  var cwd = get(options, 'cwd', '')
  if type(cwd) != v:t_string || trim(cwd) == ''
    # the agent works on the project of the current buffer
    var buffer_directory = expand('%:p:h')
    cwd = buffer_directory == '' ? getcwd() : buffer_directory
  endif
  var resolved = simplify(fnamemodify(expand(cwd), ':p'))
  # ACP requires absolute paths, a trailing separator only confuses agents
  if len(resolved) > 1
    resolved = substitute(resolved, '[\\/]\+$', '', '')
  endif
  if !isdirectory(resolved)
    util.Throw('acp: working directory does not exist: ' .. resolved)
  endif
  return resolved
enddef

def McpServers(options: dict<any>): list<any>
  var servers = get(options, 'mcp_servers', [])
  if type(servers) == v:t_list
    return servers
  endif
  if type(servers) == v:t_string && trim(servers) != ''
    var decoded: any = v:none
    try
      decoded = json_decode(servers)
    catch
      util.Throw('acp: `mcp_servers` is not valid json')
    endtry
    return type(decoded) == v:t_list ? decoded : []
  endif
  return []
enddef

# Only the capabilities the plugin can actually serve are advertised. Terminal
# support is left out on purpose, executing commands is the agent's job.
def ClientCapabilities(options: dict<any>): dict<any>
  var enable_fs = cfg.Enabled(get(options, 'enable_fs', 1))
  return {
    fs: {
      readTextFile: enable_fs,
      writeTextFile: enable_fs,
    },
    terminal: false,
  }
enddef

# ---------------------------------------------------------------------------
# public interface
# ---------------------------------------------------------------------------

# Starts a turn. `prompt` is `{full: blocks, last: blocks}`: `full` describes
# the whole conversation and is used when the agent has no session yet, `last`
# is the current user message and is used when an existing session continues.
# Returns a handle accepted by `vim_ai_http.Wait`, `Cancel`, `Error` and
# `IsDone`.
export def Request(options: dict<any>, prompt: dict<any>, OnChunk: any,
    OnDone: any = v:none): dict<any>
  var key = SessionKey(options)
  if !AllowsReuse(options)
    serial += 1
    key ..= '#' .. serial
  endif

  var handle: dict<any> = {
    transport: 'acp',
    done: false,
    cancelled: false,
    error: '',
    stop_reason: '',
    key: key,
    options: options,
    prompt: prompt,
    blocks: [],
    on_chunk: OnChunk,
    on_done: OnDone,
    session: v:none,
    last_output: reltime(),
    wait_fn: (h) => Wait(h),
    cancel_fn: (h) => Cancel(h),
    error_fn: (h) => h.error,
    is_done_fn: (h) => h.done,
  }

  try
    var session = AcquireSession(key, options)
    handle.session = session
    session.turn = handle
    if session.ready
      SendPrompt(session)
    endif
  catch
    handle.error = util.ErrorText(v:exception)
    util.Debug('acp: could not start the turn: ' .. v:exception)
    Finish(handle)
  endtry
  return handle
enddef

export def Cancel(handle: dict<any>): void
  if handle.done
    return
  endif
  handle.cancelled = true
  var session = handle.session
  if type(session) == v:t_dict && session.alive && session.session_id != ''
    util.Debug('acp: cancelling session ' .. session.session_id)
    Notify(session, 'session/cancel', {sessionId: session.session_id})
    # the agent must answer `session/prompt` with `cancelled`, but a broken one
    # must not keep the chat buffer waiting forever
    timer_start(cancel_grace_ms, (tid) => FinishIfPending(handle))
  else
    FinishIfPending(handle)
  endif
enddef

# Number of live agents, used by the tests.
export def SessionCount(): number
  return len(sessions)
enddef

# True when the session finished `initialize` and `session/new`.
export def IsReady(key: string): bool
  return get(get(sessions, key, {}), 'ready', false)
enddef

# Stops the agent of a session. A turn that is still running is ended with an
# error, closing the chat buffer must not leave a subprocess behind.
export def CloseSession(key: string): void
  var session = get(sessions, key, {})
  if empty(session)
    return
  endif
  remove(sessions, key)

  var turn = session.turn
  session.alive = false
  session.ready = false
  session.turn = v:none

  if type(session.job) == v:t_job && job_status(session.job) ==# 'run'
    util.Debug('acp: stopping the agent of ' .. key)
    job_stop(session.job)
  endif

  if type(turn) == v:t_dict && !turn.done
    if !turn.cancelled && turn.error == ''
      turn.error = 'the ACP agent was stopped'
    endif
    Finish(turn)
  endif
enddef

export def StopAll(): void
  for key in keys(sessions)
    CloseSession(key)
  endfor
enddef

# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------

def AcquireSession(key: string, options: dict<any>): dict<any>
  var existing = get(sessions, key, {})
  if !empty(existing)
    if type(existing.turn) == v:t_dict && !existing.turn.done
      util.Throw('the ACP agent is still answering, stop it with :AIStopChat')
    endif
    if existing.alive && existing.ready
      return existing
    endif
    CloseSession(key)
  endif

  var session: dict<any> = {
    key: key,
    options: options,
    command: AgentCommand(options),
    cwd: WorkingDirectory(options),
    job: v:null,
    channel: v:null,
    session_id: '',
    ready: false,
    alive: false,
    pending: '',
    stderr: [],
    callbacks: {},
    next_id: 1,
    turns: 0,
    turn: v:none,
    prompt_capabilities: {},
    agent_info: {},
    auth_methods: [],
    last_output: reltime(),
  }
  sessions[key] = session

  try
    StartAgent(session)
    Initialize(session)
  catch
    if get(sessions, key, {}) is session
      remove(sessions, key)
    endif
    session.alive = false
    throw v:exception
  endtry
  return session
enddef

def StartAgent(session: dict<any>): void
  var job: any = v:null
  try
    job = job_start(session.command, {
      cwd: session.cwd,
      in_mode: 'raw',
      out_mode: 'raw',
      err_mode: 'nl',
      out_cb: (channel, message) => OnOutput(session, channel, message),
      err_cb: (channel, message) => OnErrorOutput(session, channel, message),
      exit_cb: (j, status) => OnExit(session, j, status),
      close_cb: (channel) => OnClose(session, channel),
    })
  catch
    util.Debug('acp: job_start failed: ' .. v:exception)
  endtry

  if type(job) != v:t_job || job_status(job) ==# 'fail'
    util.Throw('failed to start the ACP agent: ' .. join(session.command, ' '))
  endif

  session.job = job
  session.channel = job_getchannel(job)
  session.alive = true
  util.Debug('acp: started ' .. join(session.command, ' ') .. ' in ' .. session.cwd)
enddef

def Send(session: dict<any>, message: dict<any>): void
  var line = json_encode(message)
  util.Debug('acp: send ' .. line)
  try
    ch_sendraw(session.channel, line .. "\n")
  catch
    # a closed channel is reported by the exit callback
    util.Debug('acp: send failed: ' .. v:exception)
  endtry
enddef

def SendRequest(session: dict<any>, method: string, params: any, OnResult: any,
    OnError: any): void
  if !session.alive
    call(OnError, ['the ACP agent is not running', 0])
    return
  endif
  var id = session.next_id
  session.next_id += 1
  session.callbacks[string(id)] = {on_result: OnResult, on_error: OnError}
  util.Debug('acp: request ' .. method .. ' #' .. id)
  Send(session, {jsonrpc: '2.0', id: id, method: method, params: params})
enddef

def Notify(session: dict<any>, method: string, params: any): void
  if !session.alive
    return
  endif
  util.Debug('acp: notification ' .. method)
  Send(session, {jsonrpc: '2.0', method: method, params: params})
enddef

def Respond(session: dict<any>, id: any, result: any): void
  Send(session, {jsonrpc: '2.0', id: id, result: result})
enddef

def RespondError(session: dict<any>, id: any, code: number, message: string): void
  Send(session, {jsonrpc: '2.0', id: id, error: {code: code, message: message}})
enddef

def OnOutput(session: dict<any>, channel: channel, message: string): void
  session.last_output = reltime()
  session.pending ..= message

  var newline = stridx(session.pending, "\n")
  while newline >= 0
    var line = strpart(session.pending, 0, newline)
    session.pending = strpart(session.pending, newline + 1)
    HandleLine(session, line)
    newline = stridx(session.pending, "\n")
  endwhile
enddef

def OnErrorOutput(session: dict<any>, channel: channel, message: string): void
  session.stderr->add(message)
  if len(session.stderr) > 20
    remove(session.stderr, 0)
  endif
  util.Debug('acp: stderr: ' .. message)
enddef

def OnExit(session: dict<any>, job: job, status: number): void
  util.Debug('acp: agent exited with ' .. status)
  var was_alive = session.alive
  session.alive = false
  session.ready = false

  if get(sessions, session.key, {}) is session
    remove(sessions, session.key)
  endif

  var turn = session.turn
  session.turn = v:none
  if type(turn) != v:t_dict || turn.done
    return
  endif

  if !turn.cancelled && turn.error == ''
    # a process that was stopped by the client is not a failure
    if !was_alive
      turn.error = 'the ACP agent was stopped'
    else
      turn.error = 'the ACP agent exited unexpectedly (exit code ' .. status .. ')'
      var details = trim(join(session.stderr, ' '), " \t\r\n")
      if details != ''
        turn.error ..= ': ' .. details
      endif
    endif
  endif
  Finish(turn)
enddef

def OnClose(session: dict<any>, channel: channel): void
  # all output has been delivered, a turn that is still waiting will be ended
  # by the exit callback which follows
  session.pending = ''
enddef

def HandleLine(session: dict<any>, raw_line: string): void
  var line = trim(raw_line, " \t\r")
  if line == ''
    return
  endif
  util.Debug('acp: recv ' .. line)

  var message: any = v:none
  try
    message = json_decode(line)
  catch
    util.Debug('acp: the agent sent invalid json')
    return
  endtry
  if type(message) != v:t_dict
    return
  endif

  if has_key(message, 'method') && has_key(message, 'id')
    HandleClientRequest(session, message)
  elseif has_key(message, 'method')
    HandleNotification(session, message)
  elseif has_key(message, 'id')
    HandleResponse(session, message)
  endif
enddef

def HandleResponse(session: dict<any>, message: dict<any>): void
  var key = string(message.id)
  var callback = get(session.callbacks, key, {})
  if empty(callback)
    util.Debug('acp: response to an unknown request #' .. key)
    return
  endif
  remove(session.callbacks, key)

  if has_key(message, 'error')
    var error = message.error
    var text = type(error) == v:t_dict ? Text(get(error, 'message', '')) : Text(error)
    var code = type(error) == v:t_dict ? get(error, 'code', 0) : 0
    if type(callback.on_error) == v:t_func
      call(callback.on_error, [text, code])
    endif
    return
  endif

  if type(callback.on_result) == v:t_func
    call(callback.on_result, [get(message, 'result', v:null)])
  endif
enddef

def HandleNotification(session: dict<any>, message: dict<any>): void
  var method = get(message, 'method', '')
  var params = get(message, 'params', {})
  if method ==# 'session/update'
    if type(params) == v:t_dict
      OnSessionUpdate(session, params)
    endif
    return
  endif
  util.Debug('acp: unhandled notification ' .. method)
enddef

# ---------------------------------------------------------------------------
# session setup
# ---------------------------------------------------------------------------

def Initialize(session: dict<any>): void
  SendRequest(session, 'initialize', {
    protocolVersion: ProtocolVersion(session.options),
    clientCapabilities: ClientCapabilities(session.options),
    clientInfo: {name: 'vim-ai', title: 'vim-ai', version: '1.0'},
  }, (result) => OnInitializeResult(session, result),
    (message, code) => FailSession(session, ErrorText(message, code)))
enddef

def OnInitializeResult(session: dict<any>, result: any): void
  if type(result) != v:t_dict
    FailSession(session, 'the agent returned an invalid initialize response')
    return
  endif

  var version = get(result, 'protocolVersion', 0)
  if type(version) == v:t_number && version != ProtocolVersion(session.options)
    FailSession(session, 'the agent speaks ACP version ' .. version
      .. ', this client supports version ' .. ProtocolVersion(session.options))
    return
  endif

  var capabilities = get(result, 'agentCapabilities', {})
  session.prompt_capabilities = type(capabilities) == v:t_dict
    ? get(capabilities, 'promptCapabilities', {}) : {}
  session.agent_info = get(result, 'agentInfo', {})
  session.auth_methods = get(result, 'authMethods', [])
  util.Debug('acp: initialized with ' .. json_encode(session.agent_info))

  var auth_method = trim(Text(get(session.options, 'auth_method', '')))
  if auth_method != ''
    SendRequest(session, 'authenticate', {methodId: auth_method},
      (response) => SendNewSession(session),
      (message, code) => FailSession(session, ErrorText(message, code)))
    return
  endif

  SendNewSession(session)
enddef

def SendNewSession(session: dict<any>): void
  SendRequest(session, 'session/new', {
    cwd: session.cwd,
    mcpServers: McpServers(session.options),
  }, (result) => OnNewSessionResult(session, result),
    (message, code) => FailSession(session, ErrorText(message, code)))
enddef

def OnNewSessionResult(session: dict<any>, result: any): void
  var session_id = type(result) == v:t_dict ? get(result, 'sessionId', '') : ''
  if type(session_id) != v:t_string || session_id == ''
    FailSession(session, 'the agent did not return a session id')
    return
  endif

  session.session_id = session_id
  session.ready = true
  util.Debug('acp: session ' .. session_id .. ' created')

  if type(session.turn) == v:t_dict
    SendPrompt(session)
  endif
enddef

# ---------------------------------------------------------------------------
# prompt turn
# ---------------------------------------------------------------------------

def SendPrompt(session: dict<any>): void
  var turn: dict<any> = session.turn
  turn.blocks = SelectBlocks(session)
  turn.last_output = reltime()
  SendRequest(session, 'session/prompt', {
    sessionId: session.session_id,
    prompt: turn.blocks,
  }, (result) => OnPromptResult(turn, result),
    (message, code) => OnPromptError(turn, message, code))
enddef

# The first turn of a session has to describe the whole conversation, later
# turns only add the new user message, the agent remembers the rest.
def SelectBlocks(session: dict<any>): list<any>
  var turn: dict<any> = session.turn
  var prompt = turn.prompt
  var blocks: list<any> = session.turns == 0 ? get(prompt, 'full', []) : get(prompt, 'last', [])
  session.turns += 1
  return FilterBlocks(session, blocks)
enddef

# Content the agent did not advertise is dropped instead of failing the prompt.
def FilterBlocks(session: dict<any>, blocks: list<any>): list<any>
  var capabilities = session.prompt_capabilities
  var result: list<any> = []
  var dropped: list<string> = []

  for block in blocks
    if type(block) != v:t_dict
      continue
    endif
    var block_type = get(block, 'type', '')
    if block_type ==# 'image' && !cfg.Enabled(get(capabilities, 'image', 0))
      dropped->add('image')
      continue
    elseif block_type ==# 'resource' && !cfg.Enabled(get(capabilities, 'embeddedContext', 0))
      dropped->add('file')
      continue
    elseif block_type ==# 'audio' && !cfg.Enabled(get(capabilities, 'audio', 0))
      dropped->add('audio')
      continue
    endif
    result->add(block)
  endfor

  if !empty(dropped)
    EmitChunk(session.turn, 'info',
      'the ACP agent does not accept ' .. join(uniq(sort(dropped)), '/') .. ' attachments, they were dropped')
  endif

  if empty(result)
    result->add({type: 'text', text: 'continue'})
  endif
  return result
enddef

def OnPromptResult(turn: dict<any>, result: any): void
  if type(result) == v:t_dict
    turn.stop_reason = Text(get(result, 'stopReason', ''))
  endif
  if turn.stop_reason ==# 'cancelled'
    turn.cancelled = true
  endif
  Finish(turn)
enddef

def OnPromptError(turn: dict<any>, message: string, code: number): void
  if turn.cancelled
    Finish(turn)
    return
  endif
  turn.error = ErrorText(message, code)
  Finish(turn)
enddef

def FinishIfPending(handle: dict<any>): void
  if handle.done
    return
  endif
  handle.cancelled = true
  Finish(handle)
enddef

def Finish(handle: dict<any>): void
  if handle.done
    return
  endif
  handle.done = true

  var session = handle.session
  if type(session) == v:t_dict
    if type(session.turn) == v:t_dict && session.turn is handle
      session.turn = v:none
    endif
    # a one-shot agent has nothing left to do, a chat session stays alive
    if !AllowsReuse(handle.options)
      CloseSession(session.key)
    endif
  endif

  util.Debug('acp: turn finished (stop reason: ' .. handle.stop_reason
    .. ', error: ' .. handle.error .. ')')

  if type(handle.on_done) == v:t_func
    call(handle.on_done, [handle])
  endif
enddef

def FailSession(session: dict<any>, message: string): void
  var turn = session.turn
  session.turn = v:none
  if type(turn) == v:t_dict && !turn.done && turn.error == ''
    turn.error = message
  endif
  # stopping the agent ends the turn, see `CloseSession`
  CloseSession(session.key)
  if type(turn) == v:t_dict && !turn.done
    Finish(turn)
  endif
enddef

def ErrorText(message: string, code: number): string
  var text = type(message) == v:t_string && message != '' ? message : 'the agent reported an error'
  return code == 0 ? text : text .. ' (' .. code .. ')'
enddef

# ---------------------------------------------------------------------------
# waiting, cancelling
# ---------------------------------------------------------------------------

def Wait(handle: dict<any>): void
  var timeout_ms = TimeoutSeconds(handle.options) * 1000
  var start = reltime()

  try
    while !handle.done
      if timeout_ms > 0 && IdleMilliseconds(handle, start) > timeout_ms
        handle.error = 'Request timeout...'
        util.Debug('acp: no output from the agent, the turn timed out')
        Abort(handle)
        break
      endif
      sleep 10m
    endwhile
  finally
    # also runs when the wait is interrupted with CTRL-C
    if !handle.done
      if handle.error == ''
        handle.error = 'Request cancelled'
      endif
      Abort(handle)
    endif
  endtry
enddef

def IdleMilliseconds(handle: dict<any>, start: list<any>): number
  var reference = type(get(handle, 'last_output')) == v:t_list ? handle.last_output : start
  return float2nr(reltimefloat(reltime(reference)) * 1000)
enddef

# A turn that is given up on (timeout, CTRL-C) takes the whole session with it:
# the agent is probably stuck and its answer would arrive too late.
def Abort(handle: dict<any>): void
  var session = handle.session
  if type(session) == v:t_dict
    if session.alive && session.session_id != ''
      Notify(session, 'session/cancel', {sessionId: session.session_id})
    endif
    CloseSession(session.key)
  endif
  Finish(handle)
enddef

# ---------------------------------------------------------------------------
# session updates
# ---------------------------------------------------------------------------

def OnSessionUpdate(session: dict<any>, params: dict<any>): void
  var turn = session.turn
  if type(turn) != v:t_dict || turn.done
    return
  endif
  turn.last_output = reltime()

  var update = get(params, 'update', {})
  if type(update) != v:t_dict
    return
  endif
  EmitUpdate(turn, update)
enddef

def EmitUpdate(turn: dict<any>, update: dict<any>): void
  var kind = get(update, 'sessionUpdate', '')

  if kind ==# 'agent_message_chunk'
    EmitChunk(turn, 'assistant', ContentText(get(update, 'content', v:null)))
  elseif kind ==# 'agent_thought_chunk'
    EmitChunk(turn, 'thinking', ContentText(get(update, 'content', v:null)))
  elseif kind ==# 'user_message_chunk'
    # the prompt is already in the chat buffer, echoing it would duplicate it
    return
  elseif kind ==# 'tool_call'
    EmitChunk(turn, 'info', ToolCallText(update))
  elseif kind ==# 'tool_call_update'
    EmitChunk(turn, 'info', ToolUpdateText(update))
  elseif kind ==# 'plan'
    EmitChunk(turn, 'info', PlanText(update))
  elseif kind ==# 'current_mode_update'
    EmitChunk(turn, 'info', '[mode] ' .. Text(get(update, 'currentModeId', '')))
  elseif kind ==# 'notice'
    EmitChunk(turn, 'info', NoticeText(update))
  elseif kind ==# 'usage_update'
    EmitChunk(turn, 'info', UsageText(update))
  endif
  # `available_commands_update`, `session_info_update` and the compaction
  # updates do not change what the plugin shows
enddef

def EmitChunk(turn: any, chunk_type: string, content: string): void
  if content == '' || type(turn) != v:t_dict || turn.done
    return
  endif
  if type(turn.on_chunk) != v:t_func
    return
  endif
  call(turn.on_chunk, [{type: chunk_type, content: content}])
enddef

def ContentText(block: any): string
  if type(block) != v:t_dict
    return ''
  endif
  var block_type = get(block, 'type', '')
  if block_type ==# 'text'
    var text = get(block, 'text', '')
    return type(text) == v:t_string ? text : ''
  elseif block_type ==# 'resource_link'
    return '[file] ' .. Text(get(block, 'name', get(block, 'uri', '')))
  elseif block_type ==# 'resource'
    var resource = get(block, 'resource', {})
    if type(resource) == v:t_dict && type(get(resource, 'text', 0)) == v:t_string
      return get(resource, 'text', '')
    endif
    return '[resource] ' .. Text(get(resource, 'uri', ''))
  elseif block_type ==# 'image'
    return '[image]'
  elseif block_type ==# 'audio'
    return '[audio]'
  endif
  return ''
enddef

def ToolCallText(update: dict<any>): string
  var title = Text(get(update, 'title', get(update, 'toolCallId', 'tool')))
  var kind = Text(get(update, 'kind', 'other'))
  var status = Text(get(update, 'status', 'pending'))
  return '[tool] ' .. title .. ' (' .. kind .. ', ' .. status .. ')'
enddef

def ToolUpdateText(update: dict<any>): string
  var title = Text(get(update, 'title', get(update, 'toolCallId', 'tool')))
  var status = get(update, 'status', '')
  var text = '[tool] ' .. title
  if type(status) == v:t_string && status != ''
    text ..= ' (' .. status .. ')'
  endif

  var blocks = get(update, 'content', [])
  if type(blocks) == v:t_list
    for block in blocks
      if type(block) != v:t_dict
        continue
      endif
      var block_type = get(block, 'type', '')
      if block_type ==# 'content'
        var inner = ContentText(get(block, 'content', v:null))
        if inner != ''
          text ..= "\n" .. inner
        endif
      elseif block_type ==# 'diff'
        text ..= "\n[changed] " .. Text(get(block, 'path', ''))
      elseif block_type ==# 'terminal'
        text ..= "\n[terminal] " .. Text(get(block, 'terminalId', ''))
      endif
    endfor
  endif
  return text
enddef

def PlanText(update: dict<any>): string
  var lines: list<string> = ['[plan]']
  var entries = get(update, 'entries', [])
  if type(entries) == v:t_list
    for entry in entries
      if type(entry) != v:t_dict
        continue
      endif
      lines->add('- [' .. Text(get(entry, 'status', 'pending')) .. '] '
        .. Text(get(entry, 'content', '')))
    endfor
  endif
  return len(lines) == 1 ? '' : join(lines, "\n")
enddef

def NoticeText(update: dict<any>): string
  var severity = Text(get(update, 'severity', 'info'))
  var title = Text(get(update, 'title', ''))
  var description = Text(get(update, 'description', ''))
  return '[' .. severity .. '] ' .. title .. (description == '' ? '' : ': ' .. description)
enddef

def UsageText(update: dict<any>): string
  var used = get(update, 'used', 0)
  var size = get(update, 'size', 0)
  if type(used) != v:t_number || type(size) != v:t_number || size == 0
    return ''
  endif
  return '[context] ' .. used .. ' / ' .. size .. ' tokens'
enddef

# ---------------------------------------------------------------------------
# client side methods
# ---------------------------------------------------------------------------

def HandleClientRequest(session: dict<any>, message: dict<any>): void
  var method = get(message, 'method', '')
  var id = message.id
  var params = get(message, 'params', {})
  if type(params) != v:t_dict
    params = {}
  endif

  if method ==# 'fs/read_text_file'
    ReadTextFile(session, id, params)
  elseif method ==# 'fs/write_text_file'
    WriteTextFile(session, id, params)
  elseif method ==# 'session/request_permission'
    RequestPermission(session, id, params)
  else
    RespondError(session, id, -32601, 'Method not found: ' .. method)
  endif
enddef

# Serves `fs/read_text_file`. `line` is 1-based, `limit` counts lines.
def ReadTextFile(session: dict<any>, id: any, params: dict<any>): void
  if !cfg.Enabled(get(session.options, 'enable_fs', 1))
    RespondError(session, id, -32601, 'fs/read_text_file is not enabled')
    return
  endif

  var path = Text(get(params, 'path', ''))
  var lines: list<string> = []
  try
    lines = readfile(path, 'b')
  catch
    RespondError(session, id, -32000, 'Cannot read file: ' .. path)
    return
  endtry

  var first = get(params, 'line', 0)
  var limit = get(params, 'limit', 0)
  var start = type(first) == v:t_number && first > 0 ? first - 1 : 0
  if start >= len(lines)
    lines = []
  elseif start > 0
    lines = lines[start :]
  endif
  if type(limit) == v:t_number && limit > 0 && len(lines) > limit
    lines = lines[0 : limit - 1]
  endif

  util.Debug('acp: read ' .. path)
  Respond(session, id, {content: join(lines, "\n")})
enddef

# Serves `fs/write_text_file`. Buffers that show the file are reloaded, the
# agent is expected to edit the project, not the editor's copy of it.
def WriteTextFile(session: dict<any>, id: any, params: dict<any>): void
  if !cfg.Enabled(get(session.options, 'enable_fs', 1))
    RespondError(session, id, -32601, 'fs/write_text_file is not enabled')
    return
  endif

  var path = Text(get(params, 'path', ''))
  var content = get(params, 'content', '')
  if type(content) != v:t_string
    RespondError(session, id, -32602, 'Invalid content')
    return
  endif

  try
    var directory = fnamemodify(path, ':h')
    if directory != '' && !isdirectory(directory)
      mkdir(directory, 'p')
    endif
    writefile(split(content, "\n", true), path)
  catch
    RespondError(session, id, -32000, 'Cannot write file: ' .. path)
    return
  endtry

  util.Debug('acp: wrote ' .. path)
  ReloadBuffers(path)
  Respond(session, id, v:null)
enddef

# Vim cannot be blocked with a dialog from a channel callback, buffers are
# updated in place instead, which is also what a user expects after the agent
# edited a file.
def ReloadBuffers(path: string): void
  if !filereadable(path)
    return
  endif
  var lines: list<string> = []
  try
    # without the `b` flag the newline at the end of the file does not become
    # an empty last line, which is how a buffer shows the file
    lines = readfile(path)
  catch
    return
  endtry

  var wanted = NormalizePath(path)
  for info in getbufinfo()
    if !info.loaded || NormalizePath(info.name) !=# wanted
      continue
    endif
    if getbufvar(info.bufnr, '&modified')
      # the local changes are newer than what the agent wrote
      continue
    endif
    try
      ReplaceBufferLines(info.bufnr, lines)
      setbufvar(info.bufnr, '&modified', 0)
    catch
      util.Debug('acp: could not reload ' .. info.name)
    endtry
  endfor
enddef

# Absolute path with a single separator style, so that the paths of the agent
# and of the buffers can be compared. Windows paths are case insensitive.
def NormalizePath(path: string): string
  var full = simplify(fnamemodify(path, ':p'))
  full = substitute(full, '\\', '/', 'g')
  return has('win32') ? tolower(full) : full
enddef

# Replaces the lines of a loaded buffer without touching the windows that show
# it. `setbufline()` only writes existing lines, so the buffer is grown or
# shrunk first.
def ReplaceBufferLines(bufnr: number, lines: list<string>): void
  # arguments are read only in Vim9 script
  var content = empty(lines) ? [''] : lines
  var current = len(getbufline(bufnr, 1, '$'))
  if current < len(content)
    appendbufline(bufnr, '$', repeat([''], len(content) - current))
  endif
  setbufline(bufnr, 1, content)
  if current > len(content)
    deletebufline(bufnr, len(content) + 1, '$')
  endif
enddef

def RequestPermission(session: dict<any>, id: any, params: dict<any>): void
  var choices = get(params, 'options', [])
  if type(choices) != v:t_list
    choices = []
  endif

  var mode = PermissionMode(session.options)
  var option_id = ''
  if mode ==# 'allow'
    option_id = PickOption(choices, 'allow')
  elseif mode ==# 'deny'
    option_id = PickOption(choices, 'reject')
  else
    option_id = AskPermission(params, choices)
  endif

  if option_id == ''
    Respond(session, id, {outcome: {outcome: 'cancelled'}})
    return
  endif
  util.Debug('acp: permission granted with ' .. option_id)
  Respond(session, id, {outcome: {outcome: 'selected', optionId: option_id}})
enddef

def PickOption(options: list<any>, kind_prefix: string): string
  for option in options
    if type(option) != v:t_dict
      continue
    endif
    if stridx(Text(get(option, 'kind', '')), kind_prefix) == 0
      return Text(get(option, 'optionId', ''))
    endif
  endfor
  return ''
enddef

def AskPermission(params: dict<any>, options: list<any>): string
  if empty(options)
    return ''
  endif

  var tool = get(params, 'toolCall', {})
  var title = 'The agent requests permission'
  if type(tool) == v:t_dict
    title = Text(get(tool, 'title', get(tool, 'toolCallId', title)))
  endif

  var labels: list<string> = []
  for option in options
    if type(option) != v:t_dict
      continue
    endif
    labels->add(Text(get(option, 'name', get(option, 'optionId', '?'))))
  endfor

  var choice = 0
  try
    choice = confirm(substitute(title, "\n", ' ', 'g'), join(labels, "\n"), 0, 'Question: ')
  catch
    # the prompt is not always possible, for example in `vim -es`
    util.Debug('acp: could not ask for permission: ' .. v:exception)
    choice = 0
  endtry

  if choice <= 0 || choice > len(options)
    var rejected = PickOption(options, 'reject')
    util.Debug('acp: permission request was not answered, rejecting it')
    return rejected
  endif
  return Text(get(options[choice - 1], 'optionId', ''))
enddef
