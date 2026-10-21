vim9script

import autoload 'vim_ai_buffer.vim' as bufmod
import autoload 'vim_ai_chat.vim' as chat
import autoload 'vim_ai_http.vim' as http
import autoload 'vim_ai_provider.vim' as prov
import autoload 'vim_ai_util.vim' as util

# `:AI` - completion and `:AIEdit` - replacement of a region.
# Replaces `py/complete.py`.

export def Run(context: dict<any>): void
  var command_type: string = context.command_type
  var prompt: string = context.prompt
  var config: dict<any> = context.config
  var provider_name: string = get(config, 'provider', 'openai')
  var options: dict<any> = get(config, 'options', {})

  try
    if get(config, 'engine', '') ==# 'complete'
      util.Throw('complete engine is no longer supported')
    endif

    if prompt == '' && empty(context.roles)
      return
    endif

    echo 'Completing...'
    redraw

    var messages = BuildMessages(options, prompt)
    util.Debug('[' .. command_type .. '] text:' .. "\n"
      .. join(GetMessageTexts(messages), "\n"))

    var provider_options = prov.Invoke(provider_name, 'Prepare', command_type, options)
    var state: dict<any> = {insert: context.insert, started: false, text: ''}
    var handle = prov.Invoke(provider_name, 'Request', command_type, provider_options,
      messages, (chunk) => OnChunk(state, chunk))
    http.Wait(handle)

    var error = http.Error(handle)
    if error != ''
      util.Throw(error)
    endif

    if trim(state.text) == ''
      util.Throw('Empty response received. Tip: You can try modifying the prompt and retry.')
    endif

    util.ClearEcho()
  catch
    util.ReportError(provider_name, v:exception)
    util.Debug('[' .. command_type .. '] error: ' .. v:exception .. ' @ ' .. v:throwpoint)
  endtry
enddef

export def BuildMessages(options: dict<any>, prompt: string): list<any>
  var initial_prompt = get(options, 'initial_prompt', [])
  var prefix = type(initial_prompt) == v:t_list ? join(initial_prompt, "\n") : initial_prompt
  return chat.ParseMessages(trim(prefix .. "\n\n>>> user\n\n" .. prompt))
enddef

def GetMessageTexts(messages: list<any>): list<string>
  var texts: list<string> = []
  for message in messages
    for part in message.content
      if get(part, 'type', '') ==# 'text'
        texts->add(get(part, 'text', ''))
      endif
    endfor
  endfor
  return texts
enddef

def OnChunk(state: dict<any>, chunk: dict<any>): void
  if chunk.type !=# 'assistant'
    # `thinking` sections are not rendered
    return
  endif

  var text: string = chunk.content
  if !state.started
    text = trim(text, " \t\r\n", 1)
  endif
  if text == ''
    return
  endif

  state.started = true
  state.text ..= text
  bufmod.InsertText(state.insert, text)
  try
    undojoin
  catch
  endtry
  redraw
enddef
