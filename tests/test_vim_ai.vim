vim9script

# Test suite for vim-ai, run with:
#   vim -es -N -u NONE -S tests/test_vim_ai.vim
#
# Results are written to tests/test-results.txt, the exit code is 1 when at
# least one check failed.

const root = expand('<script>:p:h:h')
const results_file = root .. '/tests/test-results.txt'
const resources = root .. '/tests/resources'

var results: list<string> = []
var failures = 0

# ---------------------------------------------------------------------------
# harness
# ---------------------------------------------------------------------------

def Report(name: string, ok: bool, detail: string)
  if ok
    results->add('ok   ' .. name)
  else
    failures += 1
    results->add('FAIL ' .. name .. (detail == '' ? '' : "\n     " .. detail))
  endif
enddef

def Equal(name: string, actual: any, expected: any)
  var actual_text = string(actual)
  var expected_text = string(expected)
  Report(name, actual_text ==# expected_text,
    'expected: ' .. expected_text .. "\n     actual:   " .. actual_text)
enddef

# `value != 0` would throw for strings, so the type is checked explicitly
def IsTruthy(value: any): bool
  var value_type = type(value)
  if value_type == v:t_bool
    return value
  elseif value_type == v:t_number
    return value != 0
  elseif value_type == v:t_float
    return value != 0.0
  elseif value_type == v:t_string
    return value != ''
  endif
  return !empty(value)
enddef

def Truthy(name: string, value: any, ...detail: list<string>)
  Report(name, IsTruthy(value),
    'expected a truthy value, got: ' .. string(value) .. (empty(detail) ? '' : "\n     " .. detail[0]))
enddef

def Falsy(name: string, value: any, ...detail: list<string>)
  Report(name, !IsTruthy(value),
    'expected a falsy value, got: ' .. string(value) .. (empty(detail) ? '' : "\n     " .. detail[0]))
enddef

# the results are written after every case, so a hanging test still leaves a
# trail of what already ran
def Flush()
  writefile(results + ['', failures == 0 ? 'PASSED' : 'FAILED: ' .. failures .. ' check(s)'], results_file)
enddef

def Case(name: string, Test: func(): void)
  try
    Test()
  catch
    failures += 1
    results->add('FAIL ' .. name .. "\n     unexpected error: " .. v:exception
      .. "\n     " .. v:throwpoint)
  endtry
  Flush()
enddef

# ---------------------------------------------------------------------------
# plugin
# ---------------------------------------------------------------------------

def TestPlugin()
  Equal('command :AI exists', exists(':AI'), 2)
  Equal('command :AIEdit exists', exists(':AIEdit'), 2)
  Equal('command :AIChat exists', exists(':AIChat'), 2)
  Equal('command :AIImage exists', exists(':AIImage'), 2)
  Equal('command :AIRedo exists', exists(':AIRedo'), 2)
  Equal('command :AIStopChat exists', exists(':AIStopChat'), 2)
  Equal('registered providers', sort(keys(g:vim_ai_providers)), ['openai'])
  Equal('provider module', g:vim_ai_providers.openai.module, 'vim_ai_provider_openai')
  # `exists('*vim_ai#AIRun')` does not load autoload scripts, `function()` does
  Equal('public functions', type(function('vim_ai#AIRun')) == v:t_func, true)
enddef

def TestConfig()
  Equal('chat open command', g:vim_ai_chat.ui.open_chat_command, 'preset_below')
  Equal('chat paste mode', g:vim_ai_chat.ui.paste_mode, 1)
  Equal('complete selection boundary', g:vim_ai_complete.options.selection_boundary, '#####')
  Equal('image provider', g:vim_ai_image.provider, 'openai')
  Equal('edit defaults to complete provider options',
    g:vim_ai_openai_edit.model, g:vim_ai_openai_complete.model)
  Truthy('curl path', g:vim_ai_curl_path)

  Equal('Enabled(1)', vim_ai_config#Enabled(1), true)
  Equal("Enabled('1')", vim_ai_config#Enabled('1'), true)
  Equal('Enabled(0)', vim_ai_config#Enabled(0), false)
  Equal("Enabled('0')", vim_ai_config#Enabled('0'), false)
  Equal('Enabled(v:true)', vim_ai_config#Enabled(true), true)

  Equal('ExtendDeep', vim_ai_config#ExtendDeep({a: {b: 1, c: 2}}, {a: {c: 3}}), {a: {b: 1, c: 3}})
  # the defaults must not be modified by ExtendDeep
  var defaults: dict<any> = {nested: {value: 1}}
  vim_ai_config#ExtendDeep(defaults, {nested: {value: 2}})
  Equal('ExtendDeep input untouched', defaults, {nested: {value: 1}})
enddef

def TestBuffer()
  enew!
  setline(1, ['abc', 'def'])
  var state = vim_ai_buffer#InsertState(1, 3)
  vim_ai_buffer#InsertText(state, 'XYZ')
  Equal('insert into line', getline(1, '$'), ['abcXYZ', 'def'])
  Equal('insertion point after insert', [state.lnum, state.column], [1, 6])

  vim_ai_buffer#InsertText(state, "\nnext\nlines")
  Equal('insert with newlines', getline(1, '$'), ['abcXYZ', 'next', 'lines', 'def'])
  Equal('insertion point after multiline', [state.lnum, state.column], [3, 5])

  Equal('AppendLines', vim_ai_buffer#AppendLines(['tail']).lnum, 5)
  Equal('appended line', getline(5), 'tail')

  enew!
  setline(1, ['one', 'two', 'three', 'four'])
  vim_ai_buffer#DeleteLines(2, 3)
  Equal('DeleteLines', getline(1, '$'), ['one', '', 'four'])

  enew!
  setline(1, ['aaa bbb ccc'])
  setpos("'<", [0, 1, 5, 0])
  setpos("'>", [0, 1, 7, 0])
  set selection=inclusive
  var visual_state = vim_ai_buffer#DeleteVisualSelection()
  Equal('DeleteVisualSelection charwise', getline(1), 'aaa  ccc')
  Equal('DeleteVisualSelection insertion point', visual_state.column, 4)

  enew!
  setline(1, ['first', 'second', 'third'])
  setpos("'<", [0, 2, 1, 0])
  setpos("'>", [0, 2, 2147483647, 0])
  vim_ai_buffer#DeleteVisualSelection()
  Equal('DeleteVisualSelection linewise', getline(1, '$'), ['first', '', 'third'])
enddef

def TestBase64()
  Equal('encode Hello', vim_ai_util#Base64Encode(0z48656C6C6F), 'SGVsbG8=')
  Equal('encode two bytes', vim_ai_util#Base64Encode(0z4869), 'SGk=')
  Equal('encode one byte', vim_ai_util#Base64Encode(0z48), 'SA==')
  Equal('encode empty', vim_ai_util#Base64Encode(0z), '')
  Equal('decode Hello', vim_ai_util#Base64Decode('SGVsbG8='), 0z48656C6C6F)
  Equal('decode without padding', vim_ai_util#Base64Decode('SGk'), 0z4869)
  var data = list2blob(map(range(500), (_, index) => (index * 37 + 11) % 256))
  Equal('roundtrip 500 bytes', vim_ai_util#Base64Decode(vim_ai_util#Base64Encode(data)), data)
enddef

def TestIni()
  var roles = vim_ai_util#ReadIniFiles([root .. '/roles-example.ini'])
  Equal('section names', index(keys(roles), 'refactor') >= 0, true)
  Equal('simple value', roles['grammar']['prompt'], 'fix spelling and grammar')
  Equal('dotted key', roles['refactor']['options.temperature'], '0.4')
  Equal('multi line value', roles['refactor']['prompt'],
    "\nYou are a Clean Code expert, I have the following code,"
    .. "\nplease refactor it in a more clean and concise way so that my colleagues"
    .. "\ncan maintain the code more easily. Also, explain why you want to refactor"
    .. "\nthe code so that I can add the explanation to the Pull Request.")
  Equal('empty value', roles['o1-mini']['options.initial_prompt'], '')

  # sections without keys are kept, `roles-default.ini` relies on that
  var defaults = vim_ai_util#ReadIniFiles([root .. '/roles-default.ini'])
  Equal('sections without keys', defaults['populate.chat'], {})
  Equal('empty section', defaults['default'], {})
enddef

def TestRoles()
  var saved = g:vim_ai_roles_config_file
  g:vim_ai_roles_config_file = resources .. '/roles.ini'
  var roles = vim_ai_context#ReadRoles()

  Equal('role names for chat',
    vim_ai_context#RoleNames(roles, 'chat'),
    ['all_params', 'below', 'chat-only-role', 'deprecated-test-role',
     'deprecated-test-role-simple', 'populate', 'populate-all', 'right', 'tab',
     'test-role', 'test-role-openrouter-reasoning', 'test-role-simple'])
  Equal('role names for image', vim_ai_context#RoleNames(roles, 'image'), ['high', 'medium-size'])
  Equal('role names for complete', vim_ai_context#RoleNames(roles, 'complete'),
    ['deprecated-test-role', 'deprecated-test-role-simple', 'test-role',
     'test-role-openrouter-reasoning', 'test-role-simple'])
  # the `default` role is always present but is not offered by completion
  Equal('default role is hidden', index(vim_ai_context#RoleNames(roles, 'chat'), 'default'), -1)
  Truthy('default role exists', !empty(vim_ai_context#LoadRoleConfig(roles, 'default')))
  Equal('sections without command are usable', index(vim_ai_context#RoleNames(roles, 'complete'), 'test-role-simple') >= 0, true)

  var config = vim_ai_context#LoadRoleConfig(roles, 'test-role')
  Equal('role default options', config.role_default.options.model, 'model-common')
  Equal('role default ui', config.role_default.ui.paste_mode, '0')
  Equal('role chat options', config.role_chat.options.endpoint_url, 'https://localhost/chat')
  Equal('role edit options', config.role_edit.options.endpoint_url, 'https://localhost/edit')

  var deprecated = vim_ai_context#LoadRoleConfig(roles, 'deprecated-test-role')
  Equal('deprecated role options', deprecated.role_default.options.model, 'model-common')
  Equal('deprecated role chat options', deprecated.role_chat.options.endpoint_url, 'https://localhost/chat')
  Equal('deprecated role chat ui', deprecated.role_chat.ui.open_chat_command, 'preset_tab')

  var missing_error = ''
  try
    vim_ai_context#LoadRoleConfig(roles, 'does-not-exist')
  catch
    missing_error = v:exception
  endtry
  Equal('missing role', missing_error =~# 'Role `does-not-exist` not found', true)
  g:vim_ai_roles_config_file = saved
enddef

def TestRoleNames()
  Equal('no roles', vim_ai_context#ParseRoleNames('explain this'), [])
  Equal('leading role', vim_ai_context#ParseRoleNames('/grammar hello'), ['grammar'])
  Equal('trailing role', vim_ai_context#ParseRoleNames('hello /grammar'), ['grammar'])
  Equal('leading and trailing',
    vim_ai_context#ParseRoleNames('/a text /b'), ['a', 'b'])
  Equal('only roles', vim_ai_context#ParseRoleNames('/a /b'), ['a', 'b'])
enddef

def TestPrompt()
  Equal('prompt without config', vim_ai_context#MakePrompt('', 'explain', '', ''), 'explain')
  Equal('prompt with selection',
    vim_ai_context#MakePrompt('', 'explain', 'some code', ''),
    "explain:\nsome code")
  Equal('selection with boundary',
    vim_ai_context#MakePrompt('', 'explain', 'some code', '#####'),
    "explain:\n#####\nsome code\n#####")
  Equal('selection that already has the boundary',
    vim_ai_context#MakePrompt('', 'explain', "#####\nsome code\n#####", '#####'),
    "explain:\n#####\nsome code\n#####")
  Equal('config prompt', vim_ai_context#MakePrompt('be nice', 'explain', '', ''),
    "be nice:\nexplain")
  Equal('selection only', vim_ai_context#MakePrompt('', '', 'some code', ''), 'some code')
  Equal('no prompt and no selection', vim_ai_context#MakePrompt('', '', '', ''), '')

  # the boundary gets the filetype when it is set to ```
  &filetype = 'python'
  Equal('filetype boundary',
    vim_ai_context#MakePrompt('', 'explain', 'code', '```'),
    "explain:\n```python\ncode\n```")
  &filetype = 'aichat'
  Equal('aichat boundary',
    vim_ai_context#MakePrompt('', 'explain', 'code', '```'),
    "explain:\n```\ncode\n```")
  &filetype = ''
enddef

def TestMessages()
  Equal('user message',
    vim_ai_chat#ParseMessages(">>> user\n\nhello"),
    [{role: 'user', content: [{type: 'text', text: 'hello'}]}])
  Equal('system message',
    vim_ai_chat#ParseMessages(">>> system\n\nbe nice"),
    [{role: 'system', content: [{type: 'text', text: 'be nice'}]}])
  Equal('conversation',
    vim_ai_chat#ParseMessages(
      ">>> system\n\nsys\n>>> user\n\nhi\n<<< assistant\n\nhello\n>>> user\n\nagain"),
    [
      {role: 'system', content: [{type: 'text', text: 'sys'}]},
      {role: 'user', content: [{type: 'text', text: 'hi'}]},
      {role: 'assistant', content: [{type: 'text', text: 'hello'}]},
      {role: 'user', content: [{type: 'text', text: 'again'}]},
    ])
  Equal('thinking is dropped',
    vim_ai_chat#ParseMessages(">>> user\n\nhi\n<<< thinking\n\nhmm"),
    [{role: 'user', content: [{type: 'text', text: 'hi'}]}])
  Equal('empty content', vim_ai_chat#ParseMessages(''), [])
  Equal('info block is not a message', vim_ai_chat#ParseMessages("<<< info\n\nsome info"), [])

  var include_path = vim_ai_util#ExpandPath(resources .. '/test1.include.txt')
  var include = vim_ai_chat#ParseMessages(
    ">>> user\n\n>>> include\n" .. include_path)
  Equal('include adds a text part',
    include[0].content[-1].text,
    '==> ' .. include_path .. ' <=='
    .. "\nhello world\n==> END OF FILE <==")

  Equal('binary include',
    vim_ai_chat#ParseMessages(
      ">>> user\n\n>>> include\n" .. resources .. "/binary_file.bin")[0].content[-1].text
      =~# 'Binary file, cannot display', true)

  var image = vim_ai_chat#ParseMessages(
    ">>> user\n\n>>> include\n" .. resources .. "/image_file.jpg")
  Equal('image include type', image[0].content[-1].type, 'image_url')
  Equal('image include url', image[0].content[-1].image_url.url =~# '^data:image/jpg;base64,', true)
enddef

def TestHeaderConfig()
  enew!
  setline(1, ['[chat]', 'provider=openai', 'options.model=header-model',
    'options.initial_prompt=hello\nworld', '', '>>> user', '', 'hi'])
  var config = vim_ai_chat#ParseHeaderConfig()
  Equal('header provider', config.provider, 'openai')
  Equal('header option', config.options.model, 'header-model')
  Equal('header initial prompt', config.options.initial_prompt, ['hello', 'world'])

  enew!
  setline(1, ['no header here'])
  Equal('missing header', vim_ai_chat#ParseHeaderConfig(), {provider: '', options: {}, ui: {}})

  enew!
  setline(1, ['[chat-options]'])
  var error = ''
  try
    vim_ai_chat#ParseHeaderConfig()
  catch
    error = v:exception
  endtry
  Truthy('deprecated [chat-options]', error =~# 'deprecated')
enddef

def TestProviderOptions()
  Equal('int conversion',
    vim_ai_provider_openai#Prepare('chat', {max_tokens: '100'}).max_tokens, 100)
  Equal('float conversion',
    vim_ai_provider_openai#Prepare('chat', {temperature: '0.5'}).temperature, 0.5)
  Equal('switch conversion',
    vim_ai_provider_openai#Prepare('chat', {stream: '0'}).stream, false)
  Equal('json conversion',
    vim_ai_provider_openai#Prepare('chat', {reasoning: '{"effort":"high"}'}).reasoning,
    {effort: 'high'})

  var error = ''
  try
    vim_ai_provider_openai#Prepare('chat', {max_tokens: 'many'})
  catch
    error = v:exception
  endtry
  Truthy('invalid value is rejected', error =~# "Invalid value for option 'max_tokens'")

  error = ''
  try
    vim_ai_provider_openai#Prepare('chat', {enable_auth: '0'})
  catch
    error = v:exception
  endtry
  Truthy('enable_auth is rejected', error =~# 'enable_auth')

  Equal('defaults are merged',
    vim_ai_provider_openai#Prepare('chat', {model: 'custom'}).endpoint_url,
    g:vim_ai_openai_chat.endpoint_url)
enddef

def TestStreamParsing()
  Equal('data line',
    vim_ai_http#ParseStreamLine('data: {"a": 1}'), {a: 1})
  Equal('carriage return', vim_ai_http#ParseStreamLine("data: {\"a\": 1}\r"), {a: 1})
  Equal('done marker', vim_ai_http#ParseStreamLine('data: [DONE]'), v:none)
  Equal('empty line', vim_ai_http#ParseStreamLine(''), v:none)
  Equal('event line', vim_ai_http#ParseStreamLine('event: ping'), v:none)
  Equal('broken json', vim_ai_http#ParseStreamLine('data: {oops'), v:none)
enddef

def TestRoleCompletion()
  var saved = g:vim_ai_roles_config_file
  g:vim_ai_roles_config_file = root .. '/roles-example.ini'
  Equal('completion needs a slash', vim_ai#RoleCompletionChat('grammar', '', 0), [])
  Equal('completion filter', vim_ai#RoleCompletionChat('/re', '', 0), ['/refactor'])
  Equal('image completion', vim_ai#RoleCompletionImage('/', '', 0), ['/high'])
  g:vim_ai_roles_config_file = saved
enddef

# ---------------------------------------------------------------------------
# end to end tests, they need the fake curl scripts (a POSIX shell)
# ---------------------------------------------------------------------------

def HasFakeCurl(): bool
  return !empty(FakeCurlCommand('fake_curl.sh'))
enddef

# Windows cannot execute the shell scripts directly, there they are run through
# a POSIX shell (Git for Windows provides one).
def FakeCurlCommand(script: string): list<string>
  var path = root .. '/tests/' .. script
  if executable(path) != 0
    return [path]
  endif
  for name in ['sh', 'bash']
    if executable(name) != 0
      return [name, path]
    endif
  endfor
  return []
enddef

def UseFakeCurl(script: string)
  g:vim_ai_curl_path = FakeCurlCommand(script)
enddef

def PrepareEndToEnd()
  g:vim_ai_roles_config_file = root .. '/roles-example.ini'
  g:vim_ai_token_file_path = resources .. '/example.token'
  g:vim_ai_debug = 0
  g:vim_ai_async_chat = 0
  g:vim_ai_open_chat_presets.preset_below = 'below new'
  g:vim_ai_complete.options.endpoint_url = 'http://localhost/chat/completions'
  g:vim_ai_edit.options.endpoint_url = 'http://localhost/chat/completions'
  g:vim_ai_chat.options.endpoint_url = 'http://localhost/chat/completions'
  g:vim_ai_image.options.endpoint_url = 'http://localhost/images/generations'
enddef

const fake_stream_buffer = [
  '>>> user', '', 'hello', '',
  '<<< assistant', '', 'Hello world', '',
  '<<< thinking', '', 'thinking', '',
  '<<< assistant', '', '', 'Second line', '',
  '>>> user', '', '',
]

def TestCompleteEndToEnd()
  if !HasFakeCurl()
    results->add('skip completion end to end (fake curl not executable)')
    return
  endif
  UseFakeCurl('fake_curl.sh')
  enew!
  setline(1, ['line1', 'line2', 'line3'])
  # forces a new undo block, otherwise the whole test script is one block
  &undolevels = &undolevels
  cursor(2, 1)
  vim_ai#AIRun(0, {}, 'explain')
  Equal('completion output', getline(1, '$'),
    ['line1', 'line2', 'Hello world', 'Second line', 'line3'])
  Equal('cursor is back on the last line', line('.'), 2)

  undo
  Equal('completion is a single undo block', getline(1, '$'), ['line1', 'line2', 'line3'])
enddef

def TestEditEndToEnd()
  if !HasFakeCurl()
    results->add('skip edit end to end (fake curl not executable)')
    return
  endif
  UseFakeCurl('fake_curl.sh')
  enew!
  setline(1, ['aaa bbb', 'ccc ddd', 'eee fff'])
  vim_ai#AIEditRun(0, {}, 'rewrite', 2, 3)
  Equal('edit replaces the range', getline(1, '$'),
    ['aaa bbb', 'Hello world', 'Second line'])
enddef

def TestChatEndToEnd()
  if !HasFakeCurl()
    results->add('skip chat end to end (fake curl not executable)')
    return
  endif
  UseFakeCurl('fake_curl.sh')
  enew!
  setlocal buftype=nofile
  setlocal filetype=aichat
  setline(1, ['>>> user', '', 'hello'])
  vim_ai#AIChatRun(0, {})
  Equal('chat buffer', getline(1, '$'), fake_stream_buffer)
enddef

def TestChatAsyncEndToEnd()
  if !HasFakeCurl()
    results->add('skip async chat end to end (fake curl not executable)')
    return
  endif
  UseFakeCurl('fake_curl.sh')
  g:vim_ai_async_chat = 1
  enew!
  setlocal buftype=nofile
  setlocal filetype=aichat
  setline(1, ['>>> user', '', 'hello'])
  vim_ai#AIChatRun(0, {})
  var bufnr = bufnr('%')
  Equal('spinner is shown', getline('$'), '<<< answering')
  var waited = 0
  while !vim_ai_chat#IsJobDone(bufnr) && waited < 100
    sleep 50m
    vim_ai#AIChatWatch(bufnr, 0, 0)
    waited += 1
  endwhile
  # the last chunk is flushed by the watch call that sees the finished job
  vim_ai#AIChatWatch(bufnr, 0, 0)
  Equal('async chat finished', vim_ai_chat#IsJobDone(bufnr), true)
  # the async buffer must match the one of a synchronous run
  Equal('async chat output', getline(1, '$'), fake_stream_buffer)
  g:vim_ai_async_chat = 0
enddef

def TestChatRepopulate()
  enew!
  setlocal buftype=nofile
  setlocal filetype=aichat
  setline(1, ['[chat]', 'provider=openai', 'options.model=stale-model', '',
    '>>> user', '', 'hello'])
  # `/populate` rewrites the chat header, no request is made
  vim_ai#AIChatRun(0, {}, '/populate')
  var lines = getline(1, '$')
  Equal('header is rebuilt at the top', lines[0], '[chat]')
  Equal('provider line follows the header', lines[1], 'provider=openai')
  Equal('stale option is dropped', index(lines, 'options.model=stale-model'), -1)
  Truthy('chat content is preserved', index(lines, 'hello') > 1)
  Equal('old header block is not duplicated', count(lines, '[chat]'), 1)
enddef

def TestImageEndToEnd()
  if !HasFakeCurl()
    results->add('skip image end to end (fake curl not executable)')
    return
  endif
  UseFakeCurl('fake_curl_image.sh')
  var directory = tempname()
  mkdir(directory)
  g:vim_ai_image.ui.download_dir = directory
  vim_ai#AIImageRun(0, {}, 'a cat')
  var files = glob(directory .. '/vim_ai_*.png', false, true)
  Equal('image file created', len(files), 1)
  if len(files) == 1
    Equal('image content', readblob(files[0])[0 : 3], 0z89504E47)
    delete(files[0])
  endif
  delete(directory, 'd')
  g:vim_ai_image.ui.download_dir = ''
enddef

def TestHttpError()
  if !HasFakeCurl()
    results->add('skip http error (fake curl not executable)')
    return
  endif
  UseFakeCurl('fake_curl_error.sh')
  enew!
  setline(1, ['line1'])
  var messages_before = execute('messages')
  vim_ai#AIRun(0, {}, 'explain')
  var messages = execute('messages')
  Truthy('http error is reported', messages =~# 'openai: HTTP 401: Incorrect API key provided',
    messages[len(messages_before) :])
enddef

def TestNonStreamResponse()
  if !HasFakeCurl()
    results->add('skip non stream response (fake curl not executable)')
    return
  endif
  UseFakeCurl('fake_curl_json.sh')
  var options: dict<any> = g:vim_ai_complete.options
  var had_stream = has_key(options, 'stream')
  var saved = get(options, 'stream', 0)
  options.stream = 0
  enew!
  setline(1, [''])
  vim_ai#AIRun(0, {}, 'explain')
  Equal('non streamed response', getline(1, '$'), ['Hello world', 'Second line'])
  if had_stream
    options.stream = saved
  else
    remove(options, 'stream')
  endif
enddef

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

set nocompatible
execute 'set runtimepath^=' .. root
filetype plugin indent on
syntax enable
runtime! plugin/vim-ai.vim
vim_ai_config#Load()

var cases = [
  ['plugin', function('TestPlugin')],
  ['config', function('TestConfig')],
  ['buffer', function('TestBuffer')],
  ['base64', function('TestBase64')],
  ['ini', function('TestIni')],
  ['roles', function('TestRoles')],
  ['role names', function('TestRoleNames')],
  ['prompt', function('TestPrompt')],
  ['messages', function('TestMessages')],
  ['chat header', function('TestHeaderConfig')],
  ['provider options', function('TestProviderOptions')],
  ['stream parsing', function('TestStreamParsing')],
  ['role completion', function('TestRoleCompletion')],
  ['complete end to end', function('TestCompleteEndToEnd')],
  ['edit end to end', function('TestEditEndToEnd')],
  ['chat end to end', function('TestChatEndToEnd')],
  ['async chat end to end', function('TestChatAsyncEndToEnd')],
  ['chat repopulate', function('TestChatRepopulate')],
  ['image end to end', function('TestImageEndToEnd')],
  ['http error', function('TestHttpError')],
  ['non stream response', function('TestNonStreamResponse')],
]

PrepareEndToEnd()

for [name, Test] in cases
  Case(name, Test)
endfor

results->add('')
Flush()

if failures > 0
  cquit
endif
qall!
