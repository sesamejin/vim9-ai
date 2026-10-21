vim9script

const plugin_root = expand('<script>:p:h:h')

# NOTE: selection_boundary and initial_prompt is currently handled outside of provider

const initial_complete_prompt =<< trim END
>>> system

You are a general assistant.
Answer shortly, consisely and only what you are asked.
Do not provide any explanantion or comments if not requested.
If you answer in a code, do not wrap it in markdown code block.
END
const initial_chat_prompt =<< trim END
>>> system

You are a general assistant.
If you attach a code block add syntax type after ``` to enable syntax highlighting.
END

g:vim_ai_complete_default = {
  provider: 'openai',
  prompt: '',
  options: {
    selection_boundary: '#####',
    initial_prompt: initial_complete_prompt,
  },
  ui: {
    paste_mode: 1,
  },
}
g:vim_ai_edit_default = {
  provider: 'openai',
  prompt: '',
  options: {
    selection_boundary: '#####',
    initial_prompt: initial_complete_prompt,
  },
  ui: {
    paste_mode: 1,
  },
}
g:vim_ai_chat_default = {
  provider: 'openai',
  prompt: '',
  options: {
    selection_boundary: '',
    initial_prompt: initial_chat_prompt,
  },
  ui: {
    open_chat_command: 'preset_below',
    scratch_buffer_keep_open: 0,
    populate_options: 0,
    populate_all_options: 0,
    force_new_chat: 0,
    paste_mode: 1,
  },
}
g:vim_ai_image_default = {
  provider: 'openai',
  prompt: '',
  options: {},
  ui: {
    download_dir: '',
  },
}

# openai provider options
g:vim_ai_openai_complete = {
  model: 'gpt-6.1-sol',
  endpoint_url: 'https://api.openai.com/v1/chat/completions',
  max_tokens: 0,
  max_completion_tokens: 0,
  temperature: '',
  request_timeout: 20,
  stream: 1,
  auth_type: 'bearer',
  token_file_path: '',
  token_load_fn: '',
  selection_boundary: '#####',
  initial_prompt: initial_complete_prompt,
  frequency_penalty: '',
  logit_bias: '',
  logprobs: '',
  presence_penalty: '',
  reasoning_effort: '',
  seed: '',
  stop: '',
  top_logprobs: '',
  top_p: '',
  reasoning: '',
}
g:vim_ai_openai_edit = g:vim_ai_openai_complete
g:vim_ai_openai_chat = {
  model: 'gpt-6.1-sol',
  endpoint_url: 'https://api.openai.com/v1/chat/completions',
  max_tokens: 0,
  max_completion_tokens: 0,
  temperature: '',
  request_timeout: 20,
  stream: 1,
  auth_type: 'bearer',
  token_file_path: '',
  token_load_fn: '',
  selection_boundary: '',
  initial_prompt: initial_chat_prompt,
  frequency_penalty: '',
  logit_bias: '',
  logprobs: '',
  presence_penalty: '',
  reasoning_effort: '',
  seed: '',
  stop: '',
  top_logprobs: '',
  top_p: '',
  reasoning: '',
}

g:vim_ai_openai_image = {
  model: 'gpt-image-2.5-flare-2026-09-08',
  endpoint_url: 'https://api.openai.com/v1/images/generations',
  quality: 'medium',
  size: '1024x1024',
  request_timeout: 40,
  auth_type: 'bearer',
  token_file_path: '',
  token_load_fn: '',
}

g:vim_ai_open_chat_presets = get(g:, 'vim_ai_open_chat_presets', {
  preset_below: 'below new',
  preset_tab: 'tabnew',
  preset_right: 'rightbelow :55vnew | setlocal noequalalways | setlocal winfixwidth',
})

# `get(g:, name, default)` keeps a user value and only fills in the default,
# the same as the previous `if !exists()` blocks but without the boilerplate.
g:vim_ai_chat_markdown = get(g:, 'vim_ai_chat_markdown', 0)
g:vim_ai_debug = get(g:, 'vim_ai_debug', 0)
g:vim_ai_debug_log_file = get(g:, 'vim_ai_debug_log_file', '/tmp/vim_ai_debug.log')
g:vim_ai_token_file_path = get(g:, 'vim_ai_token_file_path', '~/.config/openai.token')
g:vim_ai_token_load_fn = get(g:, 'vim_ai_token_load_fn', '')
g:vim_ai_roles_config_file = get(g:, 'vim_ai_roles_config_file', plugin_root .. '/roles-example.ini')
g:vim_ai_async_chat = get(g:, 'vim_ai_async_chat', 1)
g:vim_ai_proxy = get(g:, 'vim_ai_proxy', '')
# HTTP requests are made with the external `curl` command
g:vim_ai_curl_path = get(g:, 'vim_ai_curl_path', 'curl')


# Words accepted for a config flag, the same set the provider option parser
# (`vim_ai_provider_openai#ConvertSwitch`) understands. Everything else,
# including `'0'`, `'no'` and `'off'`, is false.
const truthy_values = ['1', 'true', 'yes', 'on']

# Interpretes a config flag. Values may be given either as numbers or as
# strings (`'1'`, `'yes'`, INI files and `:let` produce the latter), Vim9 script
# does not compare those implicitly. Unrecognized strings are false, so a typo
# never switches a feature on by accident.
export def Enabled(value: any): bool
  if type(value) == v:t_string
    return index(truthy_values, tolower(trim(value))) >= 0
  endif
  return !empty(value)
enddef

# Recursively merges `override` into `defaults` and returns the merged config.
# The arguments are not modified, the result is a new dictionary.
export def ExtendDeep(defaults: dict<any>, override: dict<any>): dict<any>
  var result: dict<any> = deepcopy(defaults)
  for [key, value] in items(override)
    if type(get(result, key)) == v:t_dict && type(value) == v:t_dict
      result[key] = ExtendDeep(result[key], value)
    else
      result[key] = deepcopy(value)
    endif
  endfor
  return result
enddef

# Merges the user config (g:<config_name>) into the defaults
# (g:<config_name>_default) in place.
def MakeConfig(config_name: string)
  # `ExtendDeep` returns a deep copy, so `g:<config_name>_default` is never
  # modified by the merge
  var defaults: dict<any> = get(g:, config_name .. '_default', {})
  var override: dict<any> = get(g:, config_name, {})
  g:[config_name] = ExtendDeep(defaults, override)
enddef

MakeConfig('vim_ai_chat')
MakeConfig('vim_ai_complete')
MakeConfig('vim_ai_image')
MakeConfig('vim_ai_edit')

# nothing to do - triggers autoloading of this file
export def Load(): void
enddef
