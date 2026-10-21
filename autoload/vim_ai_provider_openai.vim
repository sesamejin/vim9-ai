vim9script

import autoload 'vim_ai_http.vim' as http
import autoload 'vim_ai_util.vim' as util

# OpenAI compatible provider.
#
# Replaces `py/providers/openai.py`. The provider is stateless: every function
# takes the already resolved options dictionary.

const option_keys = [
  'stream',
  'temperature',
  'max_tokens',
  'max_completion_tokens',
  'web_search_options',
  'frequency_penalty',
  'logit_bias',
  'logprobs',
  'presence_penalty',
  'reasoning_effort',
  'seed',
  'stop',
  'top_logprobs',
  'top_p',
  'reasoning',
]

# Name of the global holding the provider defaults for `command_type`, used when
# populating all options into a chat header.
export def DefaultOptionsVar(command_type: string): string
  return 'vim_ai_openai_' .. command_type
enddef

export def DefaultOptions(command_type: string): dict<any>
  return get(g:, DefaultOptionsVar(command_type), {})
enddef

# Merges the provider defaults with the resolved config options and converts the
# values that are given as strings (they usually come from an INI file).
export def Prepare(command_type: string, raw_options: dict<any>): dict<any>
  var options = extendnew(DefaultOptions(command_type), raw_options)

  var enable_auth = get(options, 'enable_auth', 1)
  if type(enable_auth) == v:t_string && enable_auth ==# '0'
    util.Throw('`enable_auth = 0` option is no longer supported. use `auth_type = none` instead')
  endif

  ConvertFloat(options, 'request_timeout')

  if command_type !=# 'image'
    ConvertSwitch(options, 'stream')
    ConvertInt(options, 'max_tokens')
    ConvertInt(options, 'max_completion_tokens')
    ConvertFloat(options, 'temperature')
    ConvertFloat(options, 'frequency_penalty')
    ConvertFloat(options, 'presence_penalty')
    ConvertFloat(options, 'top_p')
    ConvertInt(options, 'seed')
    ConvertInt(options, 'top_logprobs')
    ConvertSwitch(options, 'logprobs')
    ConvertJson(options, 'stop')
    ConvertJson(options, 'logit_bias')
    ConvertJson(options, 'reasoning')
  endif

  return options
enddef

# ---------------------------------------------------------------------------
# options parsing
# ---------------------------------------------------------------------------

def ConvertInt(options: dict<any>, name: string): void
  Convert(options, name, (value) => {
    if value !~# '^\s*-\?\d\+\s*$'
      util.Throw('Invalid value for option ' .. string(name) .. ': ' .. value)
    endif
    return str2nr(value)
  })
enddef

def ConvertFloat(options: dict<any>, name: string): void
  Convert(options, name, (value) => {
    if value !~# '^\s*-\?\d*\.\?\d*\([eE][-+]\?\d\+\)\?\s*$' || trim(value) == ''
      util.Throw('Invalid value for option ' .. string(name) .. ': ' .. value)
    endif
    return str2float(value)
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
    util.Throw('Invalid value for option ' .. string(name) .. ': ' .. value)
    return false
  })
enddef

def ConvertJson(options: dict<any>, name: string): void
  Convert(options, name, (value) => {
    try
      return json_decode(value)
    catch
      util.Throw('Invalid value for option ' .. string(name) .. ': ' .. value)
      return v:null
    endtry
  })
enddef

# Applies `converter` to string values only, values coming from a Vim dictionary
# already have the right type.
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

# Subset of the options that is sent to the API.
def RequestOptions(options: dict<any>): dict<any>
  var request = {model: options['model']}
  for key in option_keys
    if !has_key(options, key)
      continue
    endif
    var value = options[key]
    if type(value) == v:t_string && value == ''
      continue
    endif
    # backward compatibility: these values used to exclude the parameter
    if type(value) == v:t_number
      if key == 'temperature' && value == -1
        continue
      endif
      if (key == 'max_tokens' || key == 'max_completion_tokens') && value == 0
        continue
      endif
    endif
    request[key] = value
  endfor
  return request
enddef

# ---------------------------------------------------------------------------
# requests
# ---------------------------------------------------------------------------

# Starts a chat/completion request. Chunks are delivered to `OnChunk` as
# `{type: 'assistant'|'thinking', content: string}` dictionaries. The Funcref
# argument is capitalised, Vim9 only calls a variable that looks like a Funcref
# (`on_chunk(...)` would be looked up as a function name, see E117).
export def Request(command_type: string, options: dict<any>, messages: list<any>,
    OnChunk: any, OnDone: any = v:none): dict<any>
  var stream = StreamEnabled(options)
  var stream_key = stream ? 'delta' : 'message'
  var payload = RequestOptions(options)
  payload['messages'] = FlattenContent(messages)

  util.Debug('openai: [' .. command_type .. '] request: ' .. json_encode(payload))

  var spec: dict<any> = {
    url: options['endpoint_url'],
    headers: MakeHeaders(options),
    payload: payload,
    stream: stream,
    timeout: get(options, 'request_timeout', 20),
    proxy: get(g:, 'vim_ai_proxy', ''),
    on_response: (response) => OnResponse(command_type, stream_key, OnChunk, response),
  }
  if type(OnDone) == v:t_func
    spec['on_done'] = OnDone
  endif
  return http.Start(spec)
enddef

# Some providers (api.deepseek.com, api.groq.com) expect a flat `content` field
# for system and assistant messages.
def FlattenContent(messages: list<any>): list<any>
  var result: list<any> = []
  for message in messages
    var copy = extendnew(message, {})
    if index(['system', 'assistant'], get(copy, 'role', '')) >= 0
      var texts: list<string> = []
      for content in copy.content
        if get(content, 'type', '') ==# 'text'
          texts->add(get(content, 'text', ''))
        endif
      endfor
      copy.content = join(texts, "\n")
    endif
    result->add(copy)
  endfor
  return result
enddef

def StreamEnabled(options: dict<any>): bool
  var value = get(options, 'stream', 0)
  if type(value) == v:t_string
    return value != '' && value !=# '0'
  endif
  if type(value) == v:t_bool
    return value
  endif
  return value != 0
enddef

def OnResponse(command_type: string, stream_key: string, OnChunk: any, response: dict<any>): void
  util.Debug('openai: [' .. command_type .. '] response: ' .. json_encode(response))

  var choices = get(response, 'choices', [])
  var delta = empty(choices) ? {} : get(choices[0], stream_key, {})
  if type(delta) != v:t_dict
    delta = {}
  endif

  # deepseek and openrouter report the reasoning separately
  var thinking = TextField(delta, 'reasoning_content')
  if thinking == ''
    thinking = TextField(delta, 'reasoning')
  endif
  if thinking != ''
    OnChunk({type: 'thinking', content: thinking})
    return
  endif

  var content = TextField(delta, 'content')
  if content != ''
    OnChunk({type: 'assistant', content: content})
  endif
enddef

def TextField(source: dict<any>, key: string): string
  var value = get(source, key, '')
  return type(value) == v:t_string ? value : ''
enddef

# Requests an image and returns `{b64_data: string}` or `{error: string}`.
export def RequestImage(command_type: string, options: dict<any>, prompt: string): dict<any>
  var images: list<string> = []
  var payload = {
    prompt: prompt,
    model: options['model'],
    quality: get(options, 'quality', ''),
    size: get(options, 'size', ''),
  }
  util.Debug('openai: [' .. command_type .. '] request: ' .. json_encode(payload))

  var spec: dict<any> = {
    url: options['endpoint_url'],
    headers: MakeHeaders(options),
    payload: payload,
    stream: false,
    timeout: get(options, 'request_timeout', 40),
    proxy: get(g:, 'vim_ai_proxy', ''),
    on_response: (response) => {
      var images_data = get(response, 'data', [])
      for image in images_data
        images->add(get(image, 'b64_json', ''))
      endfor
      util.Debug('openai: [' .. command_type .. '] response: {"images_count": ' .. len(images_data) .. '}')
    },
  }

  var handle = http.Start(spec)
  http.Wait(handle)
  if http.Error(handle) != ''
    return {error: http.Error(handle)}
  endif
  if empty(images)
    util.Throw('No image was returned by the provider')
  endif
  return {b64_data: images[0]}
enddef

# ---------------------------------------------------------------------------
# authentication
# ---------------------------------------------------------------------------

def MakeHeaders(options: dict<any>): dict<string>
  var headers: dict<string> = {
    'Content-Type': 'application/json',
    'User-Agent': 'VimAI',
  }

  var auth_type = get(options, 'auth_type', 'bearer')
  if auth_type ==# 'bearer'
    var [api_key, org_id] = LoadApiKey(options)
    headers.Authorization = 'Bearer ' .. api_key
    if org_id != ''
      headers['OpenAI-Organization'] = org_id
    endif
  elseif auth_type ==# 'api-key'
    var [api_key, _] = LoadApiKey(options)
    headers['api-key'] = api_key
  endif
  return headers
enddef

# Returns `[api_key, org_id]`. The token can be stored as `<key>,<org id>`.
def LoadApiKey(options: dict<any>): list<string>
  var raw = ''
  for candidate in [
    TokenFromFile(get(options, 'token_file_path', '')),
    TokenFromFunction(get(options, 'token_load_fn', '')),
    EnvValue('OPENAI_API_KEY'),
    TokenFromFile(get(g:, 'vim_ai_token_file_path', '')),
    TokenFromFunction(get(g:, 'vim_ai_token_load_fn', '')),
  ]
    if candidate != ''
      raw = candidate
      break
    endif
  endfor

  if raw == ''
    util.Throw('Missing API key')
  endif

  var elements = split(raw, ',')
  var api_key = trim(elements[0])
  var org_id = len(elements) > 1 ? trim(elements[1]) : ''
  return [api_key, org_id]
enddef

def TokenFromFile(path: string): string
  if type(path) != v:t_string || path == ''
    return ''
  endif
  var full_path = util.ExpandPath(path)
  if !filereadable(full_path)
    return ''
  endif
  return trim(join(readfile(full_path), "\n"))
enddef

def TokenFromFunction(expression: string): string
  if type(expression) != v:t_string || expression == ''
    return ''
  endif
  var value: any = ''
  try
    value = eval(expression)
  catch
    return ''
  endtry
  return type(value) == v:t_string ? trim(value) : ''
enddef

# `getenv()` returns null for a missing variable.
def EnvValue(name: string): string
  var value = getenv(name)
  return type(value) == v:t_string ? trim(value) : ''
enddef
