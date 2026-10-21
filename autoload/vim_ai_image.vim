vim9script

import autoload 'vim_ai_provider.vim' as prov
import autoload 'vim_ai_util.vim' as util

# `:AIImage` - generates an image and stores it on disk.
# Replaces `py/image.py`.

export def Run(context: dict<any>): void
  var command_type: string = context.command_type
  var prompt: string = context.prompt
  var config: dict<any> = context.config
  var provider_name: string = get(config, 'provider', 'openai')
  var options: dict<any> = get(config, 'options', {})

  if prompt == ''
    return
  endif

  try
    echo 'Generating...'
    redraw
    util.Debug('[image] text:' .. "\n" .. prompt)

    var provider_options = prov.Invoke(provider_name, 'Prepare', command_type, options)
    var result = prov.Invoke(provider_name, 'RequestImage', command_type,
      provider_options, prompt)

    if has_key(result, 'error')
      util.Throw(result.error)
    endif

    var path = MakeImagePath(get(config, 'ui', {}))
    var data = util.Base64Decode(result.b64_data)
    writefile(data, path)

    util.ClearEcho()
    echomsg 'Image: ' .. path
  catch
    util.ReportError(provider_name, v:exception)
    util.Debug('[' .. command_type .. '] error: ' .. v:exception .. ' @ ' .. v:throwpoint)
  endtry
enddef

export def MakeImagePath(ui: dict<any>): string
  var directory = get(ui, 'download_dir', '')
  if type(directory) != v:t_string || directory == ''
    directory = getcwd()
  endif
  if directory !~ '[\\/]$'
    directory ..= '/'
  endif
  var base = directory .. 'vim_ai_' .. strftime('%Y%m%dT%H%M%S')
  # the timestamp has a one second resolution, two images requested within the
  # same second must not overwrite each other
  var path = base .. '.png'
  var index = 2
  while filereadable(path)
    path = base .. '_' .. index .. '.png'
    index += 1
  endwhile
  return path
enddef
