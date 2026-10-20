vim9script

# `:AIImage` - generates an image and stores it on disk.
# Replaces `py/image.py`.
import autoload 'vim_ai_chat.vim'
import autoload 'vim_ai_util.vim'
import autoload 'vim_ai_provider.vim'

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
        vim_ai_util.Debug('[image] text:' .. "\n" .. prompt)

        var provider_options = vim_ai_provider.Invoke(provider_name, 'Prepare', command_type, options)
        var result = vim_ai_provider.Invoke(provider_name, 'RequestImage', command_type,
            provider_options, prompt)

        if has_key(result, 'error')
            vim_ai_util.Throw(result.error)
        endif

        var path = MakeImagePath(get(config, 'ui', {}))
        var data = base64_decode(result.b64_data)
        writefile(data, path)

        vim_ai_util.ClearEcho()
        echomsg 'Image: ' .. path
    catch
        vim_ai_chat.ReportError(provider_name, v:exception)
        vim_ai_util.Debug('[' .. command_type .. '] error: ' .. v:exception .. ' @ ' .. v:throwpoint)
    endtry
enddef

export def MakeImagePath(ui: dict<any>): string
    var directory = get(ui, 'download_dir', '')
    if type(directory) != v:t_string || directory == ''
        directory = getcwd()
    endif
    var name = 'vim_ai_' .. strftime('%Y%m%dT%H%M%S') .. '.png'
    if directory =~ '[\\/]$'
        return directory .. name
    endif
    return directory .. '/' .. name
enddef
