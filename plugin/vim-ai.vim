vim9script

# Ensure Vim implements vim9script (9.0 or newer)
if !has('vim9script')
  echoerr 'vim-ai requires Vim 9.0 or newer, Neovim does not implement vim9script'
  finish
endif

vim_ai_provider#Register('openai', {
  module: 'vim_ai_provider_openai',
})

# NOTE: `:def` functions cannot take a range, so the commands pass the range
# boundaries explicitly through `<line1>` and `<line2>`.
command! -range -nargs=? -complete=customlist,vim_ai#RoleCompletionComplete AI call vim_ai#AIRun(<range>, {}, <q-args>, <line1>, <line2>)
command! -range -nargs=? -complete=customlist,vim_ai#RoleCompletionEdit AIEdit call vim_ai#AIEditRun(<range>, {}, <q-args>, <line1>, <line2>)
command! -range -nargs=? -complete=customlist,vim_ai#RoleCompletionChat AIChat call vim_ai#AIChatRun(<range>, {}, <q-args>, <line1>, <line2>)
command! -range -nargs=? -complete=customlist,vim_ai#RoleCompletionImage AIImage call vim_ai#AIImageRun(<range>, {}, <q-args>, <line1>, <line2>)
command! -nargs=? AINewChat call vim_ai#AINewChatDeprecatedRun(<f-args>)
command! AIRedo call vim_ai#AIRedoRun()
command! AIStopChat call vim_ai#AIChatStopRun()
command! AIUtilRolesOpen call vim_ai#AIUtilRolesOpen()
command! AIUtilDebugOn call vim_ai#AIUtilSetDebug(1)
command! AIUtilDebugOff call vim_ai#AIUtilSetDebug(0)
