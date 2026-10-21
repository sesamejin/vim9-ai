vim9script

import autoload 'vim_ai_config.vim' as cfg

# Generic helpers that used to live in `py/utils.py`.

const error_prefix = 'VIM_AI_ERROR: '

# ---------------------------------------------------------------------------
# errors
# ---------------------------------------------------------------------------

# Raises a "known" (user facing) error. The original implementation raised a
# `KnownError` exception, `throw` is the only way to raise a value in Vim9
# script, therefore the message carries a prefix.
export def Throw(message: string): void
  throw error_prefix .. message
enddef

export def IsError(exception: string): bool
  return stridx(exception, error_prefix) == 0
enddef

# Message of a known error without the internal prefix.
export def ErrorText(exception: string): string
  if IsError(exception)
    return strpart(exception, len(error_prefix))
  endif
  return exception
enddef

export def PrintInfo(message: string): void
  redraw
  echohl ErrorMsg
  echomsg message
  echohl None
enddef

# Prepends the provider name to the errors that are worth attributing (transport
# failures and unexpected exceptions), a known error such as `Missing API key`
# reads better on its own.
export def FormatError(provider_name: string, exception: string): string
  var text = ErrorText(exception)
  if IsError(exception)
    if text =~# '^\(HTTP \|curl \|Failed to start \)'
      return provider_name .. ': ' .. text
    endif
    return text
  endif
  # unexpected errors keep the provider name too
  return provider_name .. ': ' .. text
enddef

export def ReportError(provider_name: string, exception: string): void
  PrintInfo(FormatError(provider_name, exception))
enddef

# Clears the "Completing..." message from the status line.
export def ClearEcho(): void
  feedkeys(':', 'nx')
enddef

# ---------------------------------------------------------------------------
# debug log
# ---------------------------------------------------------------------------

export def Debug(message: string): void
  if !cfg.Enabled(g:vim_ai_debug)
    return
  endif
  var file_path = expand(g:vim_ai_debug_log_file)
  try
    writefile(['[' .. strftime('%Y-%m-%d %H:%M:%S') .. '] ' .. message], file_path, 'a')
  catch
    # logging must never break a request
  endtry
enddef

# ---------------------------------------------------------------------------
# files
# ---------------------------------------------------------------------------

export def ExpandPath(path: string): string
  return expand(path)
enddef

export def ReadTextFile(path: string): string
  var lines = readfile(ExpandPath(path), 'b')
  return join(lines, "\n")
enddef

# Expands a path or a glob pattern into a list of existing files.
export def ExpandFilePaths(path: string): list<string>
  if empty(path)
    return []
  endif
  var expanded = ExpandPath(path)
  var paths = stridx(expanded, '*') >= 0 ? glob(expanded, false, true) : [expanded]
  return filter(paths, (_, candidate) => !isdirectory(candidate))
enddef

export def IsImagePath(path: string): bool
  var extension = tolower(matchstr(path, '\.\zs[^.]*$'))
  return index(['jpg', 'jpeg', 'png', 'gif'], extension) >= 0
enddef

# Runs a shell command and returns its output lines. The command is stopped
# when it does not finish within `timeout_ms`.
export def SystemCapture(command: string, timeout_ms: number = 5000): list<string>
  var state: dict<any> = {lines: [], done: false}
  var job = job_start([&shell, &shellcmdflag, command], {
    out_cb: (ch, msg) => SystemOut(state, ch, msg),
    exit_cb: (j, status) => SystemExit(state, j, status),
    out_mode: 'nl',
    err_io: 'out',
  })
  var deadline = reltime()
  while !state.done && reltimefloat(reltime(deadline)) * 1000 < timeout_ms
    sleep 10m
  endwhile
  if !state.done
    job_stop(job)
  endif
  return state.lines
enddef

def SystemOut(state: dict<any>, channel: channel, message: string): void
  state.lines->add(message)
enddef

def SystemExit(state: dict<any>, job: job, status: number): void
  state.done = true
enddef

# ---------------------------------------------------------------------------
# base64
# ---------------------------------------------------------------------------

export def Base64Encode(data: blob): string
  return base64_encode(data)
enddef

# `base64_decode()` rejects input whose length is not a multiple of four, some
# providers leave out the padding and line breaks are common in encoded files.
export def Base64Decode(text: string): blob
  var normalized = substitute(text, '[ \t\r\n]', '', 'g')
  var remainder = len(normalized) % 4
  if remainder > 0
    normalized ..= repeat('=', 4 - remainder)
  endif
  return base64_decode(normalized)
enddef

# ---------------------------------------------------------------------------
# ini files
# ---------------------------------------------------------------------------

# Minimal INI reader following the `configparser` conventions that the role
# files rely on:
#   - `[section]` headers
#   - `key = value` and `key: value`
#   - `#` and `;` comment lines
#   - indented continuation lines, joined with a newline
# Several files are merged in order, later files override earlier ones.
export def ReadIniFiles(paths: list<string>): dict<dict<string>>
  var result: dict<dict<string>> = {}
  for path in paths
    var full_path = ExpandPath(path)
    if !filereadable(full_path)
      Throw('Role config file does not exist: ' .. full_path)
    endif
    ReadIniFile(full_path, result)
  endfor
  return result
enddef

def ReadIniFile(path: string, result: dict<dict<string>>): void
  var lines = readfile(path)
  var state: dict<any> = {section: '', entries: {}, key: '', value: []}

  # `state.entries` always points to the dict of the current section
  var index = 0
  while index < len(lines)
    var line = lines[index]
    if trim(line) == ''
      if state.key != ''
        # configparser keeps empty lines inside a multi line value, but only
        # when more indented lines follow
        var lookahead = index + 1
        while lookahead < len(lines) && trim(lines[lookahead]) == ''
          lookahead += 1
        endwhile
        if lookahead < len(lines) && lines[lookahead] =~ '^\s\+\S'
          state.value->add('')
          index += 1
          continue
        endif
      endif
      IniFlush(state)
    elseif line =~ '^\s*[#;]'
      # comment lines terminate the current value
      IniFlush(state)
    elseif line =~ '^\s*\[.*\]\s*$'
      IniFlush(state)
      state.section = matchstr(line, '^\s*\[\zs[^]]*\ze\]')
      if !has_key(result, state.section)
        result[state.section] = {}
      endif
      state.entries = result[state.section]
    elseif line =~ '^\s\+\S'
      if state.key != ''
        state.value->add(trim(line))
      endif
    else
      IniFlush(state)
      var separator = IniSeparator(line)
      if separator < 0
        Throw('Invalid config line: ' .. trim(line))
      endif
      state.key = tolower(trim(strpart(line, 0, separator)))
      state.value = [trim(strpart(line, separator + 1))]
    endif
    index += 1
  endwhile
  IniFlush(state)
enddef

# Position of the first `=` or `:`, whichever comes first, -1 when there is none.
def IniSeparator(line: string): number
  var equal = stridx(line, '=')
  var colon = stridx(line, ':')
  if equal < 0
    return colon
  endif
  if colon < 0
    return equal
  endif
  return min([equal, colon])
enddef

def IniFlush(state: dict<any>): void
  if state.key == ''
    return
  endif
  if state.section == ''
    Throw('Config value outside of a section: ' .. state.key)
  endif
  state.entries[state.key] = join(state.value, "\n")
  state.key = ''
  state.value = []
enddef
