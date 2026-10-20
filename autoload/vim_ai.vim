vim9script

vim_ai_config#Load()

# remembers last command parameters to be used in AIRedoRun
var last_is_selection = false
var last_uses_range = 0
var last_firstline = 1
var last_lastline = 1
var last_instruction = ''
var last_command = ''
var last_config: dict<any> = {}
var redo_selection_hint = -1
var redo_firstline = 1
var redo_lastline = 1

const scratch_buffer_name = '>>> AI chat'
const chat_redraw_interval = 250 # milliseconds

def StartsWith(longer: string, shorter: string): bool
  return len(shorter) <= len(longer) && longer[0 : len(shorter) - 1] ==# shorter
enddef

def GetLastChatBufferNumber(): number
  for buf in reverse(getbufinfo())
    var buf_name = bufname(buf.bufnr)
    if buf.listed && StartsWith(buf_name, scratch_buffer_name)
      return buf.bufnr
    endif
  endfor
  return -1
enddef

def GetTabLocalChatBufferNumber(): number
  var chat_bufnr: number = gettabvar(tabpagenr(), 'vim_ai_chat_bufnr', -1)
  if !bufexists(chat_bufnr) || !buflisted(chat_bufnr)
    return -1
  endif
  return chat_bufnr
enddef

def GetReusedChatBufferNumber(): number
  # reuse tab local buffer if available
  var tab_local_bufnr = GetTabLocalChatBufferNumber()
  if tab_local_bufnr != -1
    return tab_local_bufnr
  endif
  # else reuse last chat buffer
  return GetLastChatBufferNumber()
enddef

# Configures ai-chat scratch window.
# - scratch_buffer_keep_open = 0
#   - opens new ai-chat every time
#   - excludes buffer from buffer list
# - scratch_buffer_keep_open = 1
#   - opens last ai-chat buffer (unless force_new = 1)
#   - keeps the buffer in the buffer list
def OpenChatWindow(open_conf: string, force_new: bool)
  # open new buffer that will be used as a chat
  var open_cmd: string = has_key(g:vim_ai_open_chat_presets, open_conf)
    ? g:vim_ai_open_chat_presets[open_conf]
    : open_conf
  execute open_cmd

  # reuse chat in keep-open mode
  var keep_open = vim_ai_config#Enabled(g:vim_ai_chat['ui']['scratch_buffer_keep_open'])
  var reused_chat_buffer_nr = GetReusedChatBufferNumber()
  if keep_open && reused_chat_buffer_nr != -1 && !force_new
    var current_buffer = bufnr('%')
    # reuse chat buffer
    execute 'buffer ' .. reused_chat_buffer_nr
    # close new buffer that was created by `open_cmd`
    if bufloaded(current_buffer)
      # if `hidden` is turned off, the buffer is unloaded automatically
      execute 'bd ' .. current_buffer
    endif
    # set tab local chat buffer number
    settabvar(tabpagenr(), 'vim_ai_chat_bufnr', bufnr('%'))
    return
  endif

  setlocal buftype=nofile
  setlocal noswapfile
  setlocal ft=aichat
  if keep_open
    setlocal bufhidden=hide
  else
    setlocal bufhidden=wipe
  endif
  if bufexists(scratch_buffer_name)
    # spawn another window if chat already exist
    var index = 2
    while bufexists(scratch_buffer_name .. ' ' .. index)
      index += 1
    endwhile
    execute 'file ' .. scratch_buffer_name .. ' ' .. index
  else
    execute 'file ' .. scratch_buffer_name
  endif
  # set tab local chat buffer number
  settabvar(tabpagenr(), 'vim_ai_chat_bufnr', bufnr('%'))
enddef

var is_handling_paste_mode = false

def SetPaste(config: dict<any>)
  if !&paste && vim_ai_config#Enabled(get(get(config, 'ui', {}), 'paste_mode', 0))
    is_handling_paste_mode = true
    setlocal paste
  endif
enddef

def SetNoPaste()
  if is_handling_paste_mode
    setlocal nopaste
    is_handling_paste_mode = false
  endif
enddef

def GetVisualSelection(): string
  var [line_start, column_start] = getpos("'<")[1 : 2]
  var [line_end, column_end] = getpos("'>")[1 : 2]
  var lines = getline(line_start, line_end)
  if len(lines) == 0
    return ''
  endif
  # The exclusive mode means that the last character of the selection area is
  # not included in the operation scope.
  lines[-1] = lines[-1][: column_end - (&selection == 'inclusive' ? 1 : 2)]
  lines[0] = lines[0][column_start - 1 :]
  return join(lines, "\n")
enddef

def GetSelectionOrRange(is_selection: bool, is_range: bool, firstline: number, lastline: number): string
  if is_selection
    return GetVisualSelection()
  elseif is_range
    return trim(join(getline(firstline, lastline), "\n"))
  else
    return ''
  endif
enddef

# A visual range should be treated as character-wise selection only when
# command-line invocation actually came from `'<,'>...`.
export def IsVisualSelectionRange(uses_range: number, line_start: number, line_end: number, ...args: list<any>): bool
  if uses_range == 0
    return false
  endif

  if redo_selection_hint >= 0
    return redo_selection_hint != 0
      && line_start == line("'<")
      && line_end == line("'>")
  endif

  var last_cmd: string = len(args) > 0 ? args[0] : histget(':', -1)
  if last_cmd =~# '^\s*AIRedo\>'
    return line_start == line("'<") && line_end == line("'>")
  endif

  return last_cmd =~# '^\s*''<,''>' && line_start == line("'<") && line_end == line("'>")
enddef

# Resolves the optional arguments shared by the public run functions:
#   args[0] - instruction prompt
#   args[1] - first line of the region
#   args[2] - last line of the region
# When the region lines are omitted the visual selection marks are used, which
# keeps custom commands of the `exe '1,3call vim_ai#AIRun(...)'` form working.
def ParseRunArgs(args: list<any>, uses_range: number, use_redo_hint: bool): dict<any>
  var instruction = len(args) > 0 ? args[0] : ''
  var firstline: number = len(args) > 1 ? args[1] : 0
  var lastline: number = len(args) > 2 ? args[2] : 0

  if firstline <= 0 || lastline <= 0
    var visual_first = line("'<")
    var visual_last = line("'>")
    if uses_range != 0 && visual_first > 0 && visual_last >= visual_first
      firstline = visual_first
      lastline = visual_last
    else
      firstline = line('.')
      lastline = line('.')
    endif
  endif

  if use_redo_hint && redo_selection_hint >= 0
    firstline = redo_firstline
    lastline = redo_lastline
  endif

  return {
    instruction: instruction,
    # a prompt argument is passed by the commands even when it is empty, this
    # matches the `a:0` check of the original implementation
    has_instruction: len(args) > 0,
    firstline: firstline,
    lastline: lastline,
  }
enddef

# Undo history is cluttered when using async chat.
# There doesn't seem to be a way to use standard undojoin feature,
# therefore working around with undoing and pasting changes manually.
def AIChatUndoCleanup()
  var buf = bufnr()
  var done = vim_ai_chat#IsJobDone(buf)
  var chat_initiation_line: number = getbufvar(buf, 'vim_ai_chat_start_last_line', -1)
  var undo_cleaned = chat_initiation_line == -1
  if !done || undo_cleaned
    return
  endif

  var current_line_num = line('.')
  # navigate to the line where it started generating answer
  execute 'normal! ' .. chat_initiation_line .. 'G'
  normal! j
  # copy whole assistant message to the `d` register
  normal! "dyG
  # undo until user message
  while line('$') > chat_initiation_line
    normal! u
  endwhile
  # paste assistant message as a whole
  normal! "dp
  execute 'normal! ' .. current_line_num .. 'G'

  setbufvar(buf, 'vim_ai_chat_start_last_line', -1)
enddef

# Shared preparation of the run functions: resolves the region, builds the AI
# context and remembers the parameters for `:AIRedo`.
def PrepareRun(command_type: string, defaults: dict<any>, extension: dict<any>,
    args: list<any>, uses_range: number, use_redo_hint: bool): dict<any>
  var run_args = ParseRunArgs(args, uses_range, use_redo_hint)
  var instruction: string = run_args.instruction
  var firstline: number = run_args.firstline
  var lastline: number = run_args.lastline
  var is_selection = IsVisualSelectionRange(uses_range, firstline, lastline)
  var selection = GetSelectionOrRange(is_selection, uses_range != 0, firstline, lastline)

  var context: dict<any> = vim_ai_context#Make({
    config_default: defaults,
    config_extension: extension,
    user_instruction: instruction,
    user_selection: selection,
    is_selection: is_selection,
    command_type: command_type,
  })

  last_command = command_type
  last_config = extension
  last_instruction = instruction
  last_uses_range = uses_range
  last_is_selection = is_selection
  last_firstline = firstline
  last_lastline = lastline

  return {
    context: context,
    config: context.config,
    instruction: instruction,
    has_instruction: run_args.has_instruction,
    firstline: firstline,
    lastline: lastline,
    is_selection: is_selection,
  }
enddef

# Complete prompt
# - uses_range   - truty if range passed
# - config       - function scoped vim_ai_complete config
# - args[0]      - optional instruction prompt
# - args[1..2]   - optional region lines
export def AIRun(uses_range: number, config: dict<any>, ...args: list<any>): number
  var run = PrepareRun('complete', g:vim_ai_complete, config, args, uses_range, true)
  var lastline: number = run.lastline

  # continue on the last line of the region when it is empty, otherwise start a
  # new line below it
  var lnum = lastline
  var column = len(getline(lastline))
  if column > 0
    append(lastline, [''])
    lnum = lastline + 1
    column = 0
  endif
  run.context['insert'] = vim_ai_buffer#InsertState(lnum, column)

  try
    SetPaste(run.config)
    vim_ai_complete#Run(run.context)
    vim_ai_buffer#Cursor(lastline, 1)
  finally
    SetNoPaste()
  endtry
  return 0
enddef

# Edit prompt
# - uses_range   - truty if range passed
# - config       - function scoped vim_ai_edit config
# - args[0]      - optional instruction prompt
# - args[1..2]   - optional region lines
export def AIEditRun(uses_range: number, config: dict<any>, ...args: list<any>): number
  var run = PrepareRun('edit', g:vim_ai_edit, config, args, uses_range, true)

  try
    SetPaste(run.config)
    run.context['insert'] = run.is_selection
      ? vim_ai_buffer#DeleteVisualSelection()
      : vim_ai_buffer#DeleteLines(run.firstline, run.lastline)
    vim_ai_complete#Run(run.context)
  finally
    SetNoPaste()
  endtry
  return 0
enddef

# Generate image
# - uses_range   - truty if range passed
# - config       - function scoped vim_ai_image config
# - args[0]      - optional instruction prompt
# - args[1..2]   - optional region lines
export def AIImageRun(uses_range: number, config: dict<any>, ...args: list<any>): number
  var run = PrepareRun('image', g:vim_ai_image, config, args, uses_range, true)
  vim_ai_image#Run(run.context)
  return 0
enddef

def ReuseOrCreateChatWindow(config: dict<any>)
  var open_conf: string = config['ui']['open_chat_command']

  if vim_ai_config#Enabled(config['ui']['force_new_chat'])
    OpenChatWindow(open_conf, true)
    return
  endif

  if &filetype != 'aichat'
    var buffer_list_tab = tabpagebuflist(tabpagenr())

    # reuse chat in active tab
    for buf_nr in buffer_list_tab
      if StartsWith(bufname(buf_nr), scratch_buffer_name)
        win_gotoid(bufwinid(buf_nr))
        return
      endif
    endfor

    # reuse .aichat file on the same tab
    for buf_nr in buffer_list_tab
      if getbufvar(buf_nr, '&filetype') ==# 'aichat'
        win_gotoid(bufwinid(buf_nr))
        return
      endif
    endfor

    # open tab local buffer if present
    var tab_local_buffer_nr = GetTabLocalChatBufferNumber()
    if tab_local_buffer_nr != -1
      OpenChatWindow(open_conf, false)
      return
    endif

    # reuse any .aichat buffer in the session
    var open_buffer_list: list<number> = []
    for i in range(tabpagenr('$'))
      extend(open_buffer_list, tabpagebuflist(i + 1))
    endfor
    for buf_nr in reverse(sort(open_buffer_list))
      if getbufvar(buf_nr, '&filetype') ==# 'aichat'
        win_gotoid(win_findbuf(buf_nr)[0])
        return
      endif
    endfor

    # open new chat window if no active buffer found
    OpenChatWindow(open_conf, false)
  endif
enddef

# Start and answer the chat
# - uses_range   - truty if range passed
# - config       - function scoped vim_ai_chat config
# - args[0]      - optional instruction prompt
# - args[1..2]   - optional region lines
export def AIChatRun(uses_range: number, config: dict<any>, ...args: list<any>): number
  var run_args = ParseRunArgs(args, uses_range, false)
  var instruction: string = run_args.instruction
  var has_instruction: bool = run_args.has_instruction
  var firstline: number = run_args.firstline
  var lastline: number = run_args.lastline
  var is_selection = uses_range != 0 && firstline == line("'<") && lastline == line("'>")
  var selection = GetSelectionOrRange(is_selection, uses_range != 0, firstline, lastline)
  var started_from_chat = &filetype == 'aichat'

  var context: dict<any> = vim_ai_context#Make({
    config_default: g:vim_ai_chat,
    config_extension: config,
    user_instruction: instruction,
    user_selection: selection,
    is_selection: is_selection,
    command_type: 'chat',
  })
  var resolved: dict<any> = context.config
  context['prompt'] = has_instruction || uses_range != 0 ? context['prompt'] : ''
  context['started_from_chat'] = started_from_chat

  try
    SetPaste(resolved)
    ReuseOrCreateChatWindow(resolved)

    var chat_bufnr = bufnr()
    context['bufnr'] = chat_bufnr

    if !vim_ai_chat#IsJobDone(chat_bufnr)
      echoerr 'Operation in progress, wait or stop it with :AIStopChat'
      return 0
    endif

    last_command = 'chat'
    last_config = config

    if vim_ai_chat#Run(context)
      if vim_ai_config#Enabled(g:vim_ai_async_chat)
        setbufvar(chat_bufnr, 'vim_ai_chat_start_last_line', line('$'))
        # if user switches to a different buffer, setup autocommand that
        # will clean undo history after returning back
        augroup AichatUndo
          au!
          autocmd BufEnter <buffer> AIChatUndoCleanup()
        augroup END
        append(line('$'), ['', '<<< answering'])
        timer_start(0, function('vim_ai#AIChatWatch', [chat_bufnr, 0]))
      endif
    endif
  finally
    SetNoPaste()
  endtry
  return 0
enddef

# Stop current chat job
export def AIChatStopRun(): number
  if &filetype !=# 'aichat'
    echoerr 'Not in an AI chat buffer.'
    return 0
  endif
  var buf = bufnr('%')
  vim_ai_chat#CancelJob(buf)
  AIChatUndoCleanup()
  return 0
enddef

# Function called in a timer that check if there are new lines from AI and
# appends them in a buffer. It ends when AI thread is finished (or when
# stopped).
export def AIChatWatch(bufnr: number, anim_index: number, timerid: number): void
  if !bufloaded(bufnr)
    return
  endif

  # inject new lines, first check if it is done to avoid data race, we do not
  # mind if we run the timer one more time, but we want all the data
  var done = vim_ai_chat#IsJobDone(bufnr)
  var result = vim_ai_chat#PickupLines(bufnr)

  # if user scrolling over chat while answering, do not auto-scroll
  var should_prevent_autoscroll = bufnr('%') == bufnr && line('.') != line('$')

  # the last two lines are the animation placeholder, they are replaced by the
  # freshly picked up lines. Nothing is picked up only when the job is done, in
  # that case the buffer must not be touched anymore.
  if !empty(result) || !done
    deletebufline(bufnr, '$')
    if line('$') > 0
      deletebufline(bufnr, '$')
    endif
    appendbufline(bufnr, '$', result)
  endif

  # if not done, queue timer and animate
  if !done
    timer_start(chat_redraw_interval, function('vim_ai#AIChatWatch', [bufnr, anim_index + 1]))
    appendbufline(bufnr, '$', '')
    var animations = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
    var current_animation = animations[anim_index % len(animations)]
    appendbufline(bufnr, '$', '<<< answering ' .. current_animation)
  else
    AIChatUndoCleanup()
    # Clear message
    # https://neovim.discourse.group/t/how-to-clear-the-echo-message-in-the-command-line/268/3
    feedkeys(':', 'nx')
  endif

  # if window is visible and user not scrolling, auto-scroll down
  var winid = bufwinid(bufnr)
  if winid != -1 && !should_prevent_autoscroll
    win_execute(winid, 'normal! G')
  endif
enddef

# Start a new chat
# - args - optional preset shortcut (below, right, tab)
export def AINewChatDeprecatedRun(...args: list<any>): void
  echoerr ':AINew is deprecated, use pre-configured roles `/tab`, `/below`, `/right` instead (e.g. `:AIChat /right`)'
enddef

# Repeat last AI command
export def AIRedoRun(): number
  if last_command !=# 'image'
    undo
  endif
  redo_selection_hint = last_is_selection ? 1 : 0
  redo_firstline = last_firstline
  redo_lastline = last_lastline
  try
    if last_command ==# 'complete'
      AIRun(last_uses_range, last_config, last_instruction)
    elseif last_command ==# 'edit'
      AIEditRun(last_uses_range, last_config, last_instruction)
    elseif last_command ==# 'image'
      AIImageRun(last_uses_range, last_config, last_instruction)
    elseif last_command ==# 'chat'
      # chat does not need prompt, all information are in the buffer already
      AIChatRun(0, last_config)
    endif
  finally
    redo_selection_hint = -1
    redo_firstline = 1
    redo_lastline = 1
  endtry
  return 0
enddef

def RoleCompletion(lead: string, command_type: string): list<string>
  if lead !~# '^/'
    return []
  endif
  var roles: list<string> = []
  try
    roles = vim_ai_context#RoleNames(vim_ai_context#ReadRoles(), command_type)
  catch
    return []
  endtry
  return roles
    ->map((_, role) => '/' .. role)
    ->filter((_, role) => stridx(role, lead) == 0)
enddef

export def RoleCompletionComplete(lead: string, cmdline: string, cursorpos: number): list<string>
  return RoleCompletion(lead, 'complete')
enddef

export def RoleCompletionImage(lead: string, cmdline: string, cursorpos: number): list<string>
  return RoleCompletion(lead, 'image')
enddef

export def RoleCompletionEdit(lead: string, cmdline: string, cursorpos: number): list<string>
  return RoleCompletion(lead, 'edit')
enddef

export def RoleCompletionChat(lead: string, cmdline: string, cursorpos: number): list<string>
  return RoleCompletion(lead, 'chat')
enddef

export def AIUtilRolesOpen(): void
  execute 'e ' .. g:vim_ai_roles_config_file
enddef

export def AIUtilSetDebug(is_debug: any): void
  g:vim_ai_debug = is_debug
enddef
