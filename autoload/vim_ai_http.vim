vim9script

import autoload 'vim_ai_util.vim' as util

# HTTP transport based on the external `curl` command.
#
# A request is described by a spec dictionary:
#   url         - endpoint
#   headers     - dict of request headers
#   payload     - dict that is sent as JSON body
#   stream      - true when the response is a `text/event-stream`
#   timeout     - seconds, connection timeout for streams, total for the rest
#   proxy       - optional proxy url
#   on_response - funcref, called with every decoded JSON object
#   on_done     - funcref, called once the request finished (with the handle)
#
# The request body is written to a temporary file and passed to curl with
# `--data-binary @file`, which avoids any shell quoting and command line length
# limits (image payloads can be large). The request headers are written to
# another temporary file that curl reads with `--config`: a token passed with
# `--header` would be visible to every other local user in `ps` or `wmic`.

const data_prefix = 'data:'
const done_marker = '[DONE]'
# characters that need a backslash inside a double quoted curl config value
const config_specials = '"\'
# temporary files carry the request body (the whole conversation) and the api
# key, they must stay private to the current user
const restricted_permissions = 'rw-------'
# a request that produces no output for this long is considered stalled
const default_idle_ms = 180000
# absolute upper bound, a stream that trickles forever must not freeze Vim
const default_max_ms = 1800000

export def IsAvailable(): bool
  return executable(CurlCommand()[0]) != 0
enddef

# `g:vim_ai_curl_path` is either the path of the curl executable or a list with
# a command prefix, for example `['wsl', 'curl']` or
# `['C:/Program Files/Git/bin/sh.exe', 'fake_curl.sh']`.
def CurlCommand(): list<string>
  var path = g:vim_ai_curl_path
  if type(path) == v:t_list
    return copy(path)
  endif
  return [path]
enddef

# Starts the request. Returns a handle that is passed to `Wait`, `IsDone`,
# `Cancel` and `Error`.
export def Start(spec: dict<any>): dict<any>
  var handle: dict<any> = {
    spec: spec,
    job: v:null,
    pending: '',
    body: [],
    stderr: [],
    done: false,
    cancelled: false,
    exit_code: 0,
    http_status: 0,
    error: '',
    body_path: tempname() .. '.json',
    header_path: tempname() .. '.headers',
    config_path: tempname() .. '.curlrc',
    last_output: reltime(),
  }

  writefile([json_encode(spec.payload)], handle.body_path, 'b')
  RestrictPermissions(handle.body_path)
  WriteConfigFile(handle)

  var job: any = v:null
  try
    job = job_start(BuildCommand(handle), {
      out_cb: (ch, msg) => OnOutput(handle, ch, msg),
      err_cb: (ch, msg) => OnErrorOutput(handle, ch, msg),
      exit_cb: (j, status) => OnExit(handle, j, status),
      close_cb: (ch) => OnClose(handle, ch),
      out_mode: 'raw',
      err_mode: 'raw',
    })
  catch
    util.Debug('job_start failed: ' .. v:exception)
  endtry
  handle.job = job

  # a failed start must not leak the temporary files, they hold the api key
  if type(job) != v:t_job || job_status(job) ==# 'fail'
    handle.error = 'Failed to start ' .. join(CurlCommand(), ' ')
    Finish(handle)
  endif
  return handle
enddef

export def BuildCommand(handle: dict<any>): list<string>
  var spec: dict<any> = handle.spec
  var args = CurlCommand() + ['--silent', '--show-error', '--no-buffer']
  # the headers live in the config file, see the comment at the top of the file
  args += ['--config', ToCurlPath(handle.config_path)]
  args += ['--request', 'POST', spec.url]
  # follow redirects, but keep the method and the body (curl would otherwise
  # turn a redirected POST into a GET)
  args += ['--location', '--max-redirs', '5', '--post301', '--post302', '--post303']
  if !empty(get(spec, 'proxy', ''))
    args += ['--proxy', spec.proxy]
  endif
  var timeout = get(spec, 'timeout', 0)
  var seconds: number = type(timeout) == v:t_float ? float2nr(timeout) : timeout
  if seconds > 0
    if spec.stream
      # the response of a stream can legitimately take a long time, only the
      # connection is bounded
      args += ['--connect-timeout', string(seconds)]
    else
      args += ['--max-time', string(seconds)]
    endif
  endif
  args += ['--dump-header', ToCurlPath(handle.header_path)]
  args += ['--data-binary', '@' .. ToCurlPath(handle.body_path)]
  return args
enddef

def ToCurlPath(path: string): string
  return substitute(path, '\\', '/', 'g')
enddef

# Writes one `header = "..."` line per request header. `escape()` protects the
# double quotes and backslashes, which curl would otherwise interpret.
def WriteConfigFile(handle: dict<any>): void
  var lines: list<string> = []
  for [name, value] in items(get(handle.spec, 'headers', {}))
    lines->add('header = "' .. escape(name .. ': ' .. value, config_specials) .. '"')
  endfor
  writefile(lines, handle.config_path)
  RestrictPermissions(handle.config_path)
enddef

# Keeps the temporary files readable by the current user only. Windows has no
# POSIX permissions, `setfperm()` fails there and reports it back.
def RestrictPermissions(path: string): void
  if has('unix') && !setfperm(path, restricted_permissions)
    util.Debug('could not restrict permissions of ' .. path)
  endif
enddef

export def IsDone(handle: dict<any>): bool
  return handle.done
enddef

# Blocks until the request finished. Must be called from the main loop, the job
# callbacks are executed while sleeping.
#
# `idle_ms` bounds the time without any output rather than the total duration,
# so a long running stream that keeps sending data is not cut off, while a
# stalled connection is detected quickly. `max_ms` is the absolute upper bound.
export def Wait(handle: dict<any>, idle_ms: number = default_idle_ms,
    max_ms: number = default_max_ms): void
  var start = reltime()
  try
    while !handle.done
      if IdleMilliseconds(handle, start) > idle_ms
        if handle.error == ''
          handle.error = 'Request timeout...'
        endif
        break
      endif
      if max_ms > 0 && float2nr(reltimefloat(reltime(start)) * 1000) > max_ms
        if handle.error == ''
          handle.error = 'Request exceeded the time limit of ' .. max_ms .. ' ms'
        endif
        break
      endif
      sleep 10m
    endwhile
  finally
    # also runs when the wait is interrupted with CTRL-C: the curl process and
    # the temporary files must not outlive the request
    if !handle.done
      if handle.error == ''
        handle.error = 'Request cancelled'
      endif
      if type(handle.job) == v:t_job && job_status(handle.job) ==# 'run'
        job_stop(handle.job)
      endif
      Finish(handle)
    endif
  endtry
enddef

# Milliseconds since the last output of the request.
def IdleMilliseconds(handle: dict<any>, start: list<any>): number
  var reference = type(get(handle, 'last_output')) == v:t_list ? handle.last_output : start
  return float2nr(reltimefloat(reltime(reference)) * 1000)
enddef

export def Cancel(handle: dict<any>): void
  handle.cancelled = true
  if type(handle.job) == v:t_job && job_status(handle.job) ==# 'run'
    job_stop(handle.job)
  endif
enddef

export def Error(handle: dict<any>): string
  return handle.error
enddef

export def RawBody(handle: dict<any>): string
  return join(handle.body, '')
enddef

def OnOutput(handle: dict<any>, channel: channel, message: string): void
  # the raw body is kept for error reporting even when the response is streamed
  handle.body->add(message)
  handle.last_output = reltime()

  if !handle.spec.stream
    return
  endif

  handle.pending ..= message
  var newline = stridx(handle.pending, "\n")
  while newline >= 0
    var line = strpart(handle.pending, 0, newline)
    handle.pending = strpart(handle.pending, newline + 1)
    HandleStreamLine(handle, line)
    newline = stridx(handle.pending, "\n")
  endwhile
enddef

def OnErrorOutput(handle: dict<any>, channel: channel, message: string): void
  handle.stderr->add(message)
enddef

def OnExit(handle: dict<any>, job: job, status: number): void
  handle.exit_code = status
enddef

# `close_cb` runs after all output has been delivered, which makes it the right
# place to finish the request.
def OnClose(handle: dict<any>, channel: channel): void
  if handle.done
    return
  endif

  if handle.spec.stream && handle.pending != ''
    HandleStreamLine(handle, handle.pending)
    handle.pending = ''
  endif

  handle.http_status = ReadStatusCode(handle.header_path)

  if !handle.spec.stream
    var text = RawBody(handle)
    if text != ''
      try
        var decoded = json_decode(text)
        if type(decoded) == v:t_dict
          handle.spec.on_response(decoded)
        endif
      catch
        # the body is not JSON, the error below reports the status code
      endtry
    endif
  endif

  # the first error wins: a timeout or a cancellation is more informative than
  # the exit code of the curl process that was stopped afterwards
  if handle.error == ''
    handle.error = MakeError(handle)
  endif
  Finish(handle)
enddef

def Finish(handle: dict<any>): void
  if handle.done
    return
  endif
  handle.done = true
  Cleanup(handle)
  if has_key(handle.spec, 'on_done')
    handle.spec.on_done(handle)
  endif
enddef

def HandleStreamLine(handle: dict<any>, raw_line: string): void
  var decoded = ParseStreamLine(raw_line)
  if type(decoded) == v:t_dict
    handle.spec.on_response(decoded)
  endif
enddef

# Decodes one line of a `text/event-stream` response. Returns the decoded JSON
# object, or `v:none` for anything that is not a data line (`event:`, comments,
# the `[DONE]` marker or invalid json).
export def ParseStreamLine(raw_line: string): any
  var line = trim(raw_line, " \t\r")
  if stridx(line, data_prefix) != 0
    return v:none
  endif
  var payload = trim(strpart(line, len(data_prefix)), " \t")
  if payload == '' || payload ==# done_marker
    return v:none
  endif
  var decoded: any = v:none
  try
    decoded = json_decode(payload)
  catch
    return v:none
  endtry
  return type(decoded) == v:t_dict ? decoded : v:none
enddef

def ReadStatusCode(path: string): number
  if !filereadable(path)
    return 0
  endif
  var status = 0
  for line in readfile(path)
    var matched = matchlist(line, '^HTTP/[0-9.]\+\s\+\(\d\{3}\)')
    if !empty(matched)
      status = str2nr(matched[1])
    endif
  endfor
  return status
enddef

def MakeError(handle: dict<any>): string
  var status: number = handle.http_status
  if status >= 400
    var message = ParseErrorMessage(RawBody(handle))
    var text = 'HTTP ' .. status
    if message != ''
      text ..= ': ' .. message
    endif
    return text
  endif

  if handle.exit_code != 0
    if handle.exit_code == 28
      return 'Request timeout...'
    endif
    var details = trim(join(handle.stderr, ''), " \t\r\n")
    return 'curl exit code ' .. handle.exit_code .. (details == '' ? '' : ': ' .. details)
  endif

  return ''
enddef

# Extracts `error.message` from an OpenAI style error response.
def ParseErrorMessage(body: string): string
  var decoded: any = v:none
  try
    decoded = json_decode(body)
  catch
    return ''
  endtry
  if type(decoded) != v:t_dict || !has_key(decoded, 'error')
    return ''
  endif
  var error = decoded.error
  if type(error) == v:t_dict
    return get(error, 'message', '')
  endif
  return type(error) == v:t_string ? error : ''
enddef

def Cleanup(handle: dict<any>): void
  for path in [handle.body_path, handle.header_path, handle.config_path]
    if filereadable(path)
      delete(path)
    endif
  endfor
enddef
