vim9script

# Chat support: message parsing, the chat header, and the async job pool.
# Replaces `py/chat.py`.

import autoload 'vim_ai_buffer.vim'
import autoload 'vim_ai_config.vim'
import autoload 'vim_ai_context.vim'
import autoload 'vim_ai_http.vim'
import autoload 'vim_ai_provider.vim'
import autoload 'vim_ai_util.vim'

const token_prefix = '<<< answering'
const user_header = '>>> user'

# ---------------------------------------------------------------------------
# chat buffer content
# ---------------------------------------------------------------------------

export def ParseMessages(content: string): list<any>
    var messages: list<any> = []
    var current_type = ''

    for line in split(content, "\n", true)
        if line ==# '>>> system'
            messages->add({role: 'system', content: [{type: 'text', text: ''}]})
            current_type = 'system'
        elseif line ==# '<<< thinking'
            # thinking messages are omitted from the conversation
            current_type = 'thinking'
        elseif line ==# '<<< assistant'
            messages->add({role: 'assistant', content: [{type: 'text', text: ''}]})
            current_type = 'assistant'
        elseif line ==# user_header
            if !empty(messages) && messages[-1].role ==# 'user'
                messages[-1].content->add({type: 'text', text: ''})
            else
                messages->add({role: 'user', content: [{type: 'text', text: ''}]})
            endif
            current_type = 'user'
        elseif line ==# '<<< tool_call'
            messages->add({role: 'assistant', content: [{type: 'text', text: ''}], tool_calls: []})
            current_type = 'tool_call'
        elseif line ==# '<<< tool_response'
            messages->add({role: 'tool', content: [{type: 'text', text: ''}]})
            current_type = 'tool_response'
        elseif line ==# '<<< info'
            current_type = 'info'
        elseif line ==# '>>> include'
            EnsureUserMessage(messages)
            current_type = 'include'
        elseif line ==# '>>> exec'
            EnsureUserMessage(messages)
            current_type = 'exec'
        else
            if empty(messages)
                continue
            endif
            if index(['assistant', 'system', 'user'], current_type) >= 0
                messages[-1].content[-1].text ..= "\n" .. line
            elseif current_type == 'include'
                for path in vim_ai_util.ExpandFilePaths(line)
                    var included = vim_ai_util.IsImagePath(path) ? MakeImageMessage(path) : MakeTextFileMessage(path)
                    messages[-1].content->add(included)
                endfor
            elseif current_type == 'exec'
                var command = trim(line)
                if command != ''
                    messages[-1].content->add(MakeExecOutputMessage(command))
                endif
            elseif index(['tool_call', 'tool_response'], current_type) >= 0
                var payload = trim(line)
                if payload != ''
                    try
                        messages[-1] = json_decode(payload)
                    catch
                        # keep the previous message, a broken tool payload should not abort
                    endtry
                endif
            endif
        endif
    endfor

    # newlines at both ends cause empty responses
    for message in messages
        for part in get(message, 'content', [])
            if get(part, 'type', '') ==# 'text'
                part.text = trim(get(part, 'text', ''))
            endif
        endfor
    endfor
    return messages
enddef

def EnsureUserMessage(messages: list<any>): void
    if empty(messages) || messages[-1].role !=# 'user'
        messages->add({role: 'user', content: []})
    endif
enddef

def MakeImageMessage(path: string): dict<any>
    var extension = matchstr(path, '\.\zs[^./]*$')
    var data = vim_ai_util.Base64Encode(readblob(path))
    return {
        type: 'image_url',
        image_url: {url: 'data:image/' .. extension .. ';base64,' .. data},
    }
enddef

def MakeTextFileMessage(path: string): dict<any>
    var head = '==> ' .. path .. ' <==' .. "\n"
    var tail = "\n==> END OF FILE <=="
    if IsBinaryFile(path)
        return {type: 'text', text: head .. 'Binary file, cannot display' .. tail}
    endif
    var body = ''
    try
        body = trim(vim_ai_util.ReadTextFile(path))
    catch
        body = 'Binary file, cannot display'
    endtry
    return {type: 'text', text: head .. body .. tail}
enddef

# A file is treated as binary when it is not valid UTF-8 (that is what makes
# the original Python implementation raise `UnicodeDecodeError`). NUL bytes are
# binary as well, Vim cannot hold them in a string.
def IsBinaryFile(path: string): bool
    var data: blob = 0z
    try
        data = readblob(path)
    catch
        return true
    endtry
    return !IsUtf8Text(blob2list(data))
enddef

def IsUtf8Text(bytes: list<number>): bool
    var count = len(bytes)
    var index = 0
    while index < count
        var byte: number = bytes[index]
        var extra = 0
        if byte == 0
            return false
        elseif byte < 0x80
            index += 1
            continue
        elseif byte >= 0xC2 && byte <= 0xDF
            extra = 1
        elseif byte >= 0xE0 && byte <= 0xEF
            extra = 2
        elseif byte >= 0xF0 && byte <= 0xF4
            extra = 3
        else
            return false
        endif
        if index + extra >= count
            return false
        endif
        for offset in range(1, extra)
            if and(bytes[index + offset], 0xC0) != 0x80
                return false
            endif
        endfor
        # overlong encodings, surrogates and code points above U+10FFFF
        var second: number = bytes[index + 1]
        if (byte == 0xE0 && second < 0xA0) || (byte == 0xED && second > 0x9F)
            return false
        endif
        if (byte == 0xF0 && second < 0x90) || (byte == 0xF4 && second > 0x8F)
            return false
        endif
        index += extra + 1
    endwhile
    return true
enddef

def MakeExecOutputMessage(command: string): dict<any>
    var output = join(vim_ai_util.SystemCapture(command, 5000), "\n")
    return {type: 'text', text: '==> ' .. command .. ' <==' .. "\n" .. output}
enddef

# ---------------------------------------------------------------------------
# chat header
# ---------------------------------------------------------------------------

export def ParseHeaderConfig(): dict<any>
    var config: dict<any> = {provider: '', options: {}, ui: {}}
    var lines = getline(1, '$')

    if index(lines, '[chat-options]') >= 0
        vim_ai_util.Throw('[chat-options] is deprecated, use new [chat] syntax')
    endif

    var header_index = index(lines, '[chat]')
    if header_index < 0
        return config
    endif

    for line in lines[header_index + 1 :]
        if stridx(line, '#') == 0
            continue
        endif
        if line == ''
            break
        endif
        var separator = stridx(line, '=')
        if separator < 0
            #vim_ai_util.Throw('Invalid [chat] config')
            continue
        endif
        var key = trim(strpart(line, 0, separator))
        var value = trim(strpart(line, separator + 1))
        if key ==# 'provider'
            config.provider = value
        else
            var dot = stridx(key, '.')
            if dot < 0
                vim_ai_util.Throw('Invalid [chat] config')
            endif
            var section = strpart(key, 0, dot)
            var option_key = strpart(key, dot + 1)
            if !has_key(config, section) || type(config[section]) != v:t_dict
                vim_ai_util.Throw('Invalid [chat] config')
            endif
            if option_key ==# 'initial_prompt'
                # the header is a single line, newlines are escaped
                config[section][option_key] = split(value, '\\n', true)
            else
                config[section][option_key] = value
            endif
        endif
    endfor

    return config
enddef

# Writes the changed options into the chat header.
def PopulateOptions(provider: string, options: dict<any>, default_options: dict<any>,
        show_default: bool)
    var lines = ['[chat]', 'provider=' .. provider]
    for [key, declared] in items(options)
        var value = declared
        var default_value = get(default_options, key, '')
        if key ==# 'initial_prompt'
            value = type(value) == v:t_list ? join(value, '\n') : value
            default_value = type(default_value) == v:t_list ? join(default_value, '\n') : default_value
        endif

        if !show_default && string(default_value) ==# string(value)
            continue
        endif

        lines->add('options.' .. key .. '=' .. (type(value) == v:t_string ? value : string(value)))
    endfor
    append(0, lines)
enddef

# Removes the `[chat]` block, used before re-populating the header.
def RemoveHeaderBlock(): void
    var lines = getline(1, '$')
    var start = index(lines, '[chat]')
    if start < 0
        return
    endif
    var end = start
    while end + 1 < len(lines) && lines[end + 1] != ''
        end += 1
    endwhile
    deletebufline(bufnr('%'), start + 1, min([end + 2, line('$')]))
enddef

def BreakUndoSequence(): void
    # breaks the undo sequence, https://vi.stackexchange.com/a/29087
    &undolevels = &undolevels
enddef

def HasUserPrompt(): bool
    for line in getline(1, '$')
        if line =~# '^>>> \(user\|exec\|include\)'
            return true
        endif
    endfor
    return false
enddef

def LastRole(): string
    var role = ''
    for line in getline(1, '$')
        var matched = matchlist(line, '^\(>>>\|<<<\) \(\w\+\)')
        if !empty(matched)
            role = matched[2]
        endif
    endfor
    return role
enddef

export def InitializeWindow(config: dict<any>, roles: list<string>, prompt: string): void
    var ui = get(config, 'ui', {})
    var lines = getline(1, '$')

    var populate = index(lines, '[chat]') < 0
        && (vim_ai_config.Enabled(get(ui, 'populate_options', 0))
        || vim_ai_config.Enabled(get(ui, 'populate_all_options', 0)))
    var re_populate = index(roles, 'populate') >= 0 || index(roles, 'populate-all') >= 0
    var populate_all = index(roles, 'populate-all') >= 0
        || vim_ai_config.Enabled(get(ui, 'populate_all_options', 0))

    if re_populate
        RemoveHeaderBlock()
    endif

    if !HasUserPrompt()
        # no user header yet, the whole buffer is the prompt
        append(0, [user_header, ''])
    endif

    if populate || re_populate
        var provider: string = get(config, 'provider', 'openai')
        var default_options = vim_ai_context.MakeOptions(
            copy(get(get(g:, 'vim_ai_chat_default', {}), 'options', {})))
        var options = get(config, 'options', {})

        if populate_all
            var provider_defaults = vim_ai_context.MakeOptions(
                vim_ai_provider.DefaultOptions(provider, 'chat'))
            var populated = extendnew(default_options, {})
            extend(populated, provider_defaults)
            extend(populated, options)
            PopulateOptions(provider, populated, {}, true)
        else
            PopulateOptions(provider, options, default_options, false)
        endif
    endif

    BreakUndoSequence()
    redraw

    var last_role = LastRole()
    if last_role != '' && index(['user', 'include', 'exec', 'info'], last_role) < 0
        # the completion was probably cancelled, start a new user block
        append(line('$'), ['', user_header, '', ''])
    endif

    if prompt != ''
        deletebufline(bufnr('%'), line('$'))
        appendbufline(bufnr('%'), line('$'), split(prompt, "\n", true))
        BreakUndoSequence()
        cursor(line('$'), 1)
        redraw
    endif
enddef

# ---------------------------------------------------------------------------
# async job pool
# ---------------------------------------------------------------------------

var job_pool: dict<dict<any>> = {}

export def IsJobDone(bufnr: number): bool
    return !has_key(job_pool, bufnr) || job_pool[bufnr].done
enddef

export def PickupLines(bufnr: number): list<string>
    if !has_key(job_pool, bufnr)
        return []
    endif
    var job = job_pool[bufnr]
    var lines = job.lines
    job.lines = []
    return lines
enddef

export def CancelJob(bufnr: number): void
    if !has_key(job_pool, bufnr)
        vim_ai_util.Debug('No active job found for bufnr ' .. bufnr .. ' to cancel.')
        return
    endif
    var job = job_pool[bufnr]
    if job.done
        vim_ai_util.Debug('Job for bufnr ' .. bufnr .. ' is already done.')
        return
    endif
    job.cancelled = true
    vim_ai_util.Debug('Cancellation signal sent to job for bufnr ' .. bufnr)
    vim_ai_http.Cancel(job.handle)
enddef

def OnJobChunk(job: dict<any>, chunk: dict<any>): void
    vim_ai_util.Debug('Received chunk: ' .. chunk.type .. ' => ' .. chunk.content)
    if job.previous_type != chunk.type
        if job.previous_type != ''
            job.buffer ..= "\n"
        endif
        job.buffer ..= "\n<<< " .. chunk.type .. "\n\n"
        job.previous_type = chunk.type
    endif
    job.buffer ..= chunk.content

    if stridx(job.buffer, "\n") >= 0
        var parts = split(job.buffer, "\n", true)
        extend(job.lines, parts[0 : -2])
        job.buffer = parts[-1]
    endif
enddef

def OnJobDone(job: dict<any>, handle: dict<any>): void
    if job.cancelled
        job.buffer ..= "\n\nCANCELLED by user"
    endif

    var error = vim_ai_http.Error(handle)
    if error != ''
        job.buffer ..= "\n\n<<< error getting response: " .. error
    endif

    extend(job.lines, split(job.buffer, "\n", true))
    job.buffer = ''

    if job.previous_type ==# 'assistant' && error == ''
        extend(job.lines, ['', user_header, '', ''])
    endif

    job.done = true
    vim_ai_util.Debug('AI chat job done')
enddef

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

export def Run(context: dict<any>): bool
    var command_type: string = context.command_type
    var prompt: string = context.prompt
    var config: dict<any> = context.config
    var roles: list<string> = context.roles
    var started_from_chat = vim_ai_config.Enabled(context.started_from_chat)
    var provider_name: string = get(config, 'provider', 'openai')

    try
        InitializeWindow(config, roles, prompt)

        var header = ParseHeaderConfig()
        var options = extendnew(get(config, 'options', {}), {})
        extend(options, header.options)
        if type(header.provider) == v:t_string && header.provider != ''
            provider_name = header.provider
        endif

        var initial_prompt = join(ToList(get(options, 'initial_prompt', [])), "\n")
        var initial_messages = ParseMessages(initial_prompt)

        var chat_content = trim(join(getline(1, '$'), "\n"))
        vim_ai_util.Debug('[' .. command_type .. '] text:' .. "\n" .. chat_content)
        var messages = initial_messages + ParseMessages(chat_content)

        if empty(messages)
            return false
        endif

        var last_content = messages[-1].content[-1]
        # an empty `:AIChat` outside of a chat buffer only initializes the window
        var should_answer = prompt != '' || started_from_chat
        var awaiting_response = get(last_content, 'type', '') !=# 'text'
            || get(last_content, 'text', '') != ''
            || has_key(messages[-1], 'tool_calls')

        if !awaiting_response || !should_answer
            return false
        endif

        redraw
        echo 'Answering...'
        redraw

        var provider_options = vim_ai_provider.Invoke(provider_name, 'Prepare', command_type, options)
        var messages_for_request = messages

        if vim_ai_config.Enabled(g:vim_ai_async_chat)
            StartAsyncJob(context, messages_for_request, provider_name, provider_options)
        else
            RunSync(command_type, messages_for_request, provider_name, provider_options)
            redraw
            vim_ai_util.ClearEcho()
        endif
        return true
    catch
        ReportError(provider_name, v:exception)
        vim_ai_util.Debug('[' .. command_type .. '] error: ' .. v:exception .. ' @ ' .. v:throwpoint)
        return false
    endtry
enddef

def ToList(value: any): list<string>
    if type(value) == v:t_list
        return value
    endif
    if type(value) == v:t_string
        return value == '' ? [] : [value]
    endif
    return []
enddef

export def ReportError(provider_name: string, exception: string): void
    vim_ai_util.PrintInfo(FormatError(provider_name, exception))
enddef

export def FormatError(provider_name: string, exception: string): string
    var text = vim_ai_util.ErrorText(exception)
    if vim_ai_util.IsError(exception)
        # transport errors read better with the provider in front
        if text =~# '^\(HTTP \|curl \|Failed to start \)'
            return provider_name .. ': ' .. text
        endif
        return text
    endif
    # unexpected errors keep the provider name too
    return provider_name .. ': ' .. text
enddef

def RunSync(command_type: string, messages: list<any>, provider_name: string,
        provider_options: dict<any>): void
    var state: dict<any> = {
        insert: vim_ai_buffer.InsertState(line('$'), len(getline('$'))),
        previous_type: '',
        started: false,
        text: '',
    }
    var handle = vim_ai_provider.Invoke(provider_name, 'Request', command_type, provider_options,
        messages, function('OnSyncChunk', [state]))
    vim_ai_http.Wait(handle)

    var error = vim_ai_http.Error(handle)
    if error != ''
        vim_ai_util.Throw(error)
    endif

    if trim(state.text) == ''
        vim_ai_util.Throw('Empty response received. Tip: You can try modifying the prompt and retry.')
    endif

    vim_ai_buffer.InsertText(state.insert, "\n\n>>> user\n\n")
enddef

def OnSyncChunk(state: dict<any>, chunk: dict<any>): void
    if state.previous_type != chunk.type
        vim_ai_buffer.InsertText(state.insert, "\n\n<<< " .. chunk.type .. "\n\n")
        state.previous_type = chunk.type
    endif

    var text: string = chunk.content
    if !state.started
        # trim newlines from the beginning
        text = trim(text, " \t\r\n", 1)
    endif
    if text == ''
        return
    endif

    state.started = true
    state.text ..= text
    vim_ai_buffer.InsertText(state.insert, text)
    try
        undojoin
    catch
    endtry
    redraw
enddef

def StartAsyncJob(context: dict<any>, messages: list<any>, provider_name: string,
        provider_options: dict<any>)
    var bufnr: number = context.bufnr
    var job: dict<any> = {
        bufnr: bufnr,
        lines: [],
        buffer: '',
        previous_type: '',
        cancelled: false,
        done: false,
        handle: v:none,
    }
    job_pool[bufnr] = job
    job.handle = vim_ai_provider.Invoke(provider_name, 'Request', provider_name, provider_options,
        messages, function('OnJobChunk', [job]), function('OnJobDone', [job]))
enddef
