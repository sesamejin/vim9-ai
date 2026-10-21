" Plain legacy script, deliberately not vim9script: functions defined in a
" vim9script file are script-local, while `g:vim_ai_roles_config_function`
" refers to a function by its global name.
function! VimAiTestCustomRoles()
  return {'test-custom-role': {'options.model': 'custom-model'}}
endfunction
