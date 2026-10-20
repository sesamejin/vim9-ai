vim9script

# Builds the AI context: resolves roles, merges the configuration and renders
# the prompt. This replaces `py/context.py` and `py/roles.py`.

const default_role_name = 'default'
const plugin_root = expand('<script>:p:h:h')

# ---------------------------------------------------------------------------
# generic dict helpers
# ---------------------------------------------------------------------------

export def MergeDeep(objects: list<any>): dict<any>
  var result: dict<any> = {}
  for object in objects
    MergeInto(result, object)
  endfor
  return result
enddef

def MergeInto(target: dict<any>, source: dict<any>): void
  for [key, value] in items(source)
    if type(value) == v:t_dict
      var child = get(target, key, {})
      if type(child) != v:t_dict
        child = {}
      endif
      target[key] = child
      MergeInto(child, value)
    else
      target[key] = value
    endif
  endfor
enddef

# ---------------------------------------------------------------------------
# roles
# ---------------------------------------------------------------------------

export def ReadRoles(): dict<dict<string>>
  var roles = vim_ai_util#ReadIniFiles([
    plugin_root .. '/roles-default.ini',
    get(g:, 'vim_ai_roles_config_file', ''),
  ])
  EnhanceRoles(roles)
  return roles
enddef

# `g:vim_ai_roles_config_function` may return additional role sections.
def EnhanceRoles(roles: dict<dict<string>>): void
  var function_name = get(g:, 'vim_ai_roles_config_function', '')
  if type(function_name) != v:t_string || function_name == ''
    return
  endif
  if !exists('*' .. function_name)
    vim_ai_util#Throw('Role config function does not exist: ' .. function_name)
  endif
  var custom = function(function_name)()
  if type(custom) == v:t_dict
    for [section, entries] in items(custom)
      roles[section] = entries
    endfor
  endif
enddef

const deprecated_sections = ['options', 'ui']
const role_postfixes = ['', '.complete', '.edit', '.chat', '.image']

def IsDeprecatedSyntax(roles: dict<dict<string>>, role: string): bool
  for section in deprecated_sections
    for command_type in ['', '-complete', '-edit', '-chat']
      if has_key(roles, role .. '.' .. section .. command_type)
        return true
      endif
    endfor
  endfor
  return false
enddef

def LoadDeprecatedRole(roles: dict<dict<string>>, role: string): dict<any>
  var prompt = get(get(roles, role, {}), 'prompt', '')
  return {
    role_default: {
      prompt: prompt,
      options: copy(get(roles, role .. '.options', {})),
      ui: copy(get(roles, role .. '.ui', {})),
    },
    role_complete: {
      prompt: prompt,
      options: copy(get(roles, role .. '.options-complete', {})),
      ui: copy(get(roles, role .. '.ui-complete', {})),
    },
    role_edit: {
      prompt: prompt,
      options: copy(get(roles, role .. '.options-edit', {})),
      ui: copy(get(roles, role .. '.ui-edit', {})),
    },
    role_chat: {
      prompt: prompt,
      options: copy(get(roles, role .. '.options-chat', {})),
      ui: copy(get(roles, role .. '.ui-chat', {})),
    },
  }
enddef

# Turns `options.model = x` style keys into nested dictionaries.
export def ParseRoleSection(section: dict<string>): dict<any>
  var result: dict<any> = {}
  for key in keys(section)
    var parts = split(key, '\.')
    var structure = len(parts) > 1 ? parts[0 : -2] : []
    var primitive = parts[-1]
    var object = result
    for path in structure
      if type(get(object, path)) != v:t_dict
        object[path] = {}
      endif
      object = object[path]
    endfor
    object[primitive] = section[key]
  endfor
  return result
enddef

export def LoadRoleConfig(roles: dict<dict<string>>, role: string): dict<any>
  var found = false
  for postfix in role_postfixes
    if has_key(roles, role .. postfix)
      found = true
      break
    endif
  endfor
  if !found
    vim_ai_util#Throw('Role `' .. role .. '` not found')
  endif

  if IsDeprecatedSyntax(roles, role)
    return LoadDeprecatedRole(roles, role)
  endif

  return {
    role_default: ParseRoleSection(get(roles, role, {})),
    role_complete: ParseRoleSection(get(roles, role .. '.complete', {})),
    role_edit: ParseRoleSection(get(roles, role .. '.edit', {})),
    role_chat: ParseRoleSection(get(roles, role .. '.chat', {})),
    role_image: ParseRoleSection(get(roles, role .. '.image', {})),
  }
enddef

# Names of the roles that are usable with `command_type`. A role is usable when
# it has a section without postfix or a section for that command. Images have to
# be defined explicitly.
export def RoleNames(roles: dict<dict<string>>, command_type: string): list<string>
  var names: dict<number> = {}
  for section in keys(roles)
    var parts = split(section, '\.')
    if command_type ==# 'image'
      if len(parts) > 1 && parts[-1] ==# command_type
        names[parts[0]] = 1
      endif
    elseif len(parts) == 1 || parts[-1] ==# command_type
      names[parts[0]] = 1
    endif
  endfor
  if has_key(names, default_role_name)
    remove(names, default_role_name)
  endif
  return sort(keys(names))
enddef

# Leading and trailing `/role` shortcuts of a prompt.
export def ParseRoleNames(prompt: string): list<string>
  var words = split(trim(prompt), '\s\+')
  var leading_count = 0
  for word in words
    if stridx(word, '/') != 0
      break
    endif
    leading_count += 1
  endfor
  var trailing_count = 0
  for word in reverse(copy(words[leading_count :]))
    if stridx(word, '/') != 0
      break
    endif
    trailing_count += 1
  endfor
  var trailing_start = trailing_count > 0 ? len(words) - trailing_count : len(words)
  var roles: list<string> = []
  for index in range(leading_count)
    roles->add(strpart(words[index], 1))
  endfor
  for word in words[trailing_start :]
    roles->add(strpart(word, 1))
  endfor
  return roles
enddef

# ---------------------------------------------------------------------------
# prompt
# ---------------------------------------------------------------------------

def MakeSelectionBoundary(selection_boundary: string): list<string>
  if selection_boundary !=# '```'
    return [selection_boundary, selection_boundary]
  endif
  var filetype = &filetype
  if filetype != '' && filetype !=# 'aichat'
    return ['```' .. filetype, '```']
  endif
  return ['```', '```']
enddef

def MakeSelectionPrompt(selection: string, user_prompt: string, config_prompt: string,
    selection_boundary: string): string
  if user_prompt == '' && config_prompt == ''
    return selection
  elseif selection != ''
    if selection_boundary != '' && stridx(selection, selection_boundary) < 0
      var [left, right] = MakeSelectionBoundary(selection_boundary)
      return left .. "\n" .. selection .. "\n" .. right
    endif
    return selection
  endif
  return ''
enddef

export def MakePrompt(config_prompt: string, user_prompt: string, selection: string,
    selection_boundary: string): string
  var instruction = trim(user_prompt)
  var delimiter = instruction != '' && selection != '' ? ":\n" : ''
  var selection_part = MakeSelectionPrompt(selection, instruction, config_prompt, selection_boundary)
  var prompt = instruction .. delimiter .. selection_part
  if config_prompt == ''
    return prompt
  endif
  delimiter = stridx(prompt, ':') == 0 ? '' : ":\n"
  return config_prompt .. delimiter .. prompt
enddef

# ---------------------------------------------------------------------------
# context
# ---------------------------------------------------------------------------

def ParsePromptAndRoleConfig(instruction: string, command_type: string): list<any>
  var trimmed = trim(instruction)
  var words = split(trimmed, '\s\+')
  var roles = ParseRoleNames(trimmed)

  var leading_count = 0
  for word in words
    if stridx(word, '/') != 0
      break
    endif
    leading_count += 1
  endfor

  var trailing_count = len(roles) - leading_count
  var trailing_start = len(words) - trailing_count
  if trailing_start < leading_count
    trailing_start = leading_count
  endif
  var user_prompt = join(words[leading_count : trailing_start - 1], ' ')

  var sections = ReadRoles()
  var role_results: list<any> = []
  for role in [default_role_name] + roles
    role_results->add(LoadRoleConfig(sections, role))
  endfor

  var parsed_role = MergeDeep(role_results)
  var config = MergeDeep([
    get(parsed_role, 'role_default', {}),
    get(parsed_role, 'role_' .. command_type, {}),
  ])
  return [user_prompt, config, roles]
enddef

# Normalizes the `initial_prompt` option to a list of lines.
export def MakeOptions(options: dict<any>): dict<any>
  var initial_prompt = get(options, 'initial_prompt', v:none)
  if type(initial_prompt) == v:t_string
    options['initial_prompt'] = split(initial_prompt, "\n", true)
  endif
  return options
enddef

# params:
#   config_default   - plugin defaults for the command, e.g. g:vim_ai_chat
#   config_extension - command specific override
#   user_instruction - the text after the command
#   user_selection   - selected text
#   command_type     - chat, complete, edit or image
export def Make(params: dict<any>): dict<any>
  var command_type: string = params.command_type
  var [user_prompt, role_config, roles] = ParsePromptAndRoleConfig(
    params.user_instruction, command_type)

  var final_config = MergeDeep([
    params.config_default,
    params.config_extension,
    role_config,
  ])

  var options = MakeOptions(get(final_config, 'options', {}))
  final_config['options'] = options

  var selection_boundary = get(options, 'selection_boundary', '')
  var config_prompt = get(final_config, 'prompt', '')
  var prompt = MakePrompt(config_prompt, user_prompt, params.user_selection, selection_boundary)

  return {
    command_type: command_type,
    config: final_config,
    prompt: prompt,
    roles: roles,
  }
enddef
