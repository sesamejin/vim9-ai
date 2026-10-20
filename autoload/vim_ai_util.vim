vim9script

# Generic helpers that used to live in `py/utils.py`.

import autoload 'vim_ai_config.vim'

const error_prefix = 'VIM_AI_ERROR: '
const b64_alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

# ---------------------------------------------------------------------------
# errors
# ---------------------------------------------------------------------------

# Returns a message that is recognisable as a "known" (user facing) error. The
# original implementation raised a `KnownError` exception, `throw` is the only
# way to raise a value in Vim9 script, therefore the message is prefixed.
export def Error(message: string): string
    return error_prefix .. message
enddef

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

# Clears the "Completing..." message from the status line.
export def ClearEcho(): void
    feedkeys(':', 'nx')
enddef

# ---------------------------------------------------------------------------
# debug log
# ---------------------------------------------------------------------------

export def Debug(message: string): void
    if !vim_ai_config.Enabled(g:vim_ai_debug)
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

export def WriteTextFile(path: string, text: string): void
    writefile(split(text, "\n", true), ExpandPath(path), 'b')
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
        out_cb: function('SystemOut', [state]),
        exit_cb: function('SystemExit', [state]),
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
    var bytes = blob2list(data)
    var count = len(bytes)
    var encoded: list<string> = []
    var index = 0
    while index < count
        var byte0: number = bytes[index]
        var byte1: number = index + 1 < count ? bytes[index + 1] : 0
        var byte2: number = index + 2 < count ? bytes[index + 2] : 0
        var triple: number = (byte0 << 16) + (byte1 << 8) + byte2
        var part = strpart(b64_alphabet, and(triple >> 18, 63), 1)
        part ..= strpart(b64_alphabet, and(triple >> 12, 63), 1)
        part ..= index + 1 < count ? strpart(b64_alphabet, and(triple >> 6, 63), 1) : '='
        part ..= index + 2 < count ? strpart(b64_alphabet, and(triple, 63), 1) : '='
        encoded->add(part)
        index += 3
    endwhile
    return join(encoded, '')
enddef

export def Base64Decode(text: string): blob
    var table = Base64Table()
    # padding does not carry information, dropping it keeps the loop simple
    var codes = str2list(substitute(text, '[^A-Za-z0-9+/]', '', 'g'), true)
    var count = len(codes)
    var decoded: list<number> = []
    var index = 0
    while index < count
        var value0: number = table[codes[index]]
        var value1: number = index + 1 < count ? table[codes[index + 1]] : 0
        var value2: number = index + 2 < count ? table[codes[index + 2]] : 0
        var value3: number = index + 3 < count ? table[codes[index + 3]] : 0
        var triple: number = (value0 << 18) + (value1 << 12) + (value2 << 6) + value3
        decoded->add(and(triple >> 16, 255))
        if index + 2 < count
            decoded->add(and(triple >> 8, 255))
        endif
        if index + 3 < count
            decoded->add(and(triple, 255))
        endif
        index += 4
    endwhile
    return list2blob(decoded)
enddef

var base64_table_cache: list<number> = []

def Base64Table(): list<number>
    if !empty(base64_table_cache)
        return base64_table_cache
    endif
    var table: list<number> = repeat([-1], 256)
    for index in range(len(b64_alphabet))
        table[char2nr(strpart(b64_alphabet, index, 1))] = index
    endfor
    base64_table_cache = table
    return table
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
