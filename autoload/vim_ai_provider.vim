vim9script

import autoload 'vim_ai_util.vim' as util

# Registry of AI providers.
#
# A provider is a module (autoload prefix) that implements:
#   Prepare(command_type, raw_options) -> options dict
#   Request(command_type, options, messages, on_chunk [, on_done]) -> handle
#   RequestImage(command_type, options, prompt) -> {b64_data} | {error}
#   DefaultOptionsVar(command_type) -> name of the global with the defaults

g:vim_ai_providers = {}

export def Register(name: string, options: dict<any>): void
  g:vim_ai_providers[name] = options
enddef

# Returns the registered provider configuration, raising a user facing error
# when the provider is unknown.
export def Resolve(name: string): dict<any>
  var providers = get(g:, 'vim_ai_providers', {})
  if !has_key(providers, name)
    util.Throw('Unknown provider: ' .. name)
  endif
  var provider = providers[name]
  if get(provider, 'module', '') == ''
    util.Throw('Provider `' .. name .. '` does not define a module')
  endif
  return provider
enddef

# Calls `function_name` of the provider module `name`. The provider name is a
# config string, so the Funcref has to be looked up at runtime; `call()` is the
# only way to pass a variable argument list to a Funcref.
export def Invoke(name: string, function_name: string, ...args: list<any>): any
  var provider = Resolve(name)
  var Handler = function(provider.module .. '#' .. function_name)
  return call(Handler, args)
enddef

# Provider defaults for `command_type`, used when populating all options into a
# chat header. Providers are free to not implement `DefaultOptionsVar`.
export def DefaultOptions(name: string, command_type: string): dict<any>
  var variable = ''
  try
    variable = Invoke(name, 'DefaultOptionsVar', command_type)
  catch
    return {}
  endtry
  return copy(get(g:, variable, {}))
enddef
