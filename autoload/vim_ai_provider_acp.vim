vim9script

import autoload 'vim_ai_acp.vim' as acp
import autoload 'vim_ai_config.vim' as cfg
import autoload 'vim_ai_util.vim' as util

# ACP (Agent Client Protocol) provider.
#
# Instead of POSTing the conversation to an endpoint, an ACP agent is started
# as a subprocess and the prompt is sent over JSON-RPC, so the agent can read
# and edit the project itself. The transport and the session handling live in
# `vim_ai_acp.vim`, this module only translates the provider interface:
#
#   provider = 'acp'
#   options.agent_command = ['claude-code-acp']
#
# The plugin keeps the conversation in the chat buffer, the agent keeps it in
# its own session. On the first turn the whole conversation is sent, every
# later turn of the same session only sends the new user message.

export def DefaultOptionsVar(command_type: string): string
  return 'vim_ai_acp_' .. command_type
enddef

export def DefaultOptions(command_type: string): dict<any>
  return get(g:, DefaultOptionsVar(command_type), {})
enddef

# Merges the provider defaults with the resolved config options and converts
# the values that are given as strings (they usually come from an INI file or
# from the chat header).
export def Prepare(command_type: string, raw_options: dict<any>): dict<any>
  var options = extendnew(DefaultOptions(command_type), raw_options)

  ConvertSwitch(options, 'enable_fs')
  ConvertSwitch(options, 'reuse_session')
  ConvertSwitch(options, 'send_system_prompt')
  ConvertInt(options, 'request_timeout')
  ConvertInt(options, 'protocol_version')
  ConvertList(options, 'agent_command')
  ConvertJson(options, 'mcp_servers')

  # `string()` would quote a string value, the mode may come from an INI file
  var raw_mode = get(options, 'permission_mode', 'ask')
  var mode = tolower(trim(type(raw_mode) == v:t_string ? raw_mode : string(raw_mode)))
  if index(['ask', 'allow', 'deny'], mode) < 0
    util.Throw('Invalid value for option permission_mode: ' .. mode
      .. ' (expected ask, allow or deny)')
  endif
  options.permission_mode = mode

  return options
enddef

# ---------------------------------------------------------------------------
# options parsing
# ---------------------------------------------------------------------------

def ConvertInt(options: dict<any>, name: string): void
  Convert(options, name, (value) => {
    if value !~# '^\s*-\?\d\+\s*$'
      util.Throw('Invalid value for option ' .. name .. ': ' .. value)
    endif
    return str2nr(value)
  })
enddef

def ConvertSwitch(options: dict<any>, name: string): void
  Convert(options, name, (value) => {
    if value =~? '^\s*\(1\|true\|yes\|on\)\s*$'
      return true
    endif
    if value =~? '^\s*\(0\|false\|no\|off\)\s*$'
      return false
    endif
    util.Throw('Invalid value for option ' .. name .. ': ' .. value)
    return false
  })
enddef

def ConvertJson(options: dict<any>, name: string): void
  Convert(options, name, (value) => {
    try
      return json_decode(value)
    catch
      util.Throw('Invalid value for option ' .. name .. ': ' .. value)
      return v:null
    endtry
  })
enddef

# A command is either a list or a string. In a role file the string form is
# the only option, a json list is accepted there as well so that arguments
# containing spaces stay possible.
def ConvertList(options: dict<any>, name: string): void
  Convert(options, name, (value) => {
    var text = trim(value)
    if text == ''
      return []
    endif
    if text[0] ==# '['
      try
        var decoded = json_decode(text)
        if type(decoded) == v:t_list
          return decoded
        endif
      catch
      endtry
      util.Throw('Invalid value for option ' .. name .. ': ' .. value)
    endif
    return split(text)
  })
enddef

# Applies `converter` to string values only, values coming from a Vim
# dictionary already have the right type.
def Convert(options: dict<any>, name: string, Converter: func(string): any): void
  if !has_key(options, name)
    return
  endif
  var value = options[name]
  if type(value) != v:t_string || value == ''
    return
  endif
  options[name] = Converter(value)
enddef

# ---------------------------------------------------------------------------
# requests
# ---------------------------------------------------------------------------

# Starts a prompt turn. Chunks are delivered to `OnChunk` as
# `{type: 'assistant'|'thinking'|'info', content: string}` dictionaries.
export def Request(command_type: string, options: dict<any>, messages: list<any>,
    OnChunk: any, OnDone: any = v:none): dict<any>
  var prompt = BuildPrompt(options, messages)
  util.Debug('acp: [' .. command_type .. '] prompt: ' .. json_encode(prompt))
  return acp.Request(options, prompt, OnChunk, OnDone)
enddef

# ACP has no separate system role and no history parameter, the conversation
# of a fresh session is rendered into a single prompt. `last` holds only the
# current user message, it is used when the agent already knows the rest.
export def BuildPrompt(options: dict<any>, messages: list<any>): dict<any>
  var include_system = cfg.Enabled(get(options, 'send_system_prompt', 1))

  # messages that actually carry text, the system prompt may be filtered out
  var included: list<dict<any>> = []
  var last_user = -1
  for index in range(len(messages))
    var message = messages[index]
    var role = get(message, 'role', 'user')
    if role ==# 'system' && !include_system
      continue
    endif
    var text = MessageText(message)
    if text == ''
      continue
    endif
    included->add({role: role, text: text, source: index})
    if role ==# 'user'
      last_user = len(included) - 1
    endif
  endfor

  var full: list<any> = []
  var last: list<any> = []
  var transcript: list<string> = []

  for index in range(len(included))
    var entry = included[index]
    # a prompt that is a single message needs no role header
    var text = len(included) == 1 ? entry.text : '### ' .. entry.role .. "\n\n" .. entry.text
    transcript->add(text)
    if index == last_user
      last->add({type: 'text', text: entry.text})
    endif
  endfor

  if !empty(transcript)
    full->add({type: 'text', text: join(transcript, "\n\n")})
  endif

  # images belong to the message they were attached to
  if last_user >= 0
    for part in get(messages[included[last_user].source], 'content', [])
      if get(part, 'type', '') !=# 'image_url'
        continue
      endif
      var image = ImageBlock(part)
      if !empty(image)
        full->add(image)
        last->add(image)
      endif
    endfor
  endif

  if empty(full)
    full->add({type: 'text', text: ''})
  endif
  if empty(last)
    last->add({type: 'text', text: ''})
  endif
  return {full: full, last: last}
enddef

def MessageText(message: dict<any>): string
  var texts: list<string> = []
  for part in get(message, 'content', [])
    if type(part) == v:t_dict && get(part, 'type', '') ==# 'text'
      texts->add(get(part, 'text', ''))
    endif
  endfor
  return trim(join(texts, "\n\n"))
enddef

# The plugin represents an attachment as a data url, ACP wants the mime type
# and the base64 payload separately.
def ImageBlock(part: dict<any>): dict<any>
  var image = get(part, 'image_url', {})
  if type(image) != v:t_dict
    return {}
  endif
  var url = get(image, 'url', '')
  if type(url) != v:t_string || stridx(url, 'data:') != 0
    return {}
  endif

  var comma = stridx(url, ',')
  if comma < 0
    return {}
  endif
  var header = strpart(url, 5, comma - 5)
  var mime_type = matchstr(header, '^[^;]*')
  if mime_type == ''
    mime_type = 'image/png'
  endif
  return {type: 'image', mimeType: mime_type, data: strpart(url, comma + 1)}
enddef

# Image generation is not part of ACP, `:AIImage` keeps using an image
# capable provider.
export def RequestImage(command_type: string, options: dict<any>, prompt: string): dict<any>
  util.Throw('the acp provider cannot generate images, configure another provider for :AIImage')
  return {error: 'not supported'}
enddef
