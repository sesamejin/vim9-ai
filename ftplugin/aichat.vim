vim9script

# Highlighting code blocks in .aichat files
# Inspired and based on https://github.com/preservim/vim-markdown

import autoload 'vim_ai_config.vim'

var filetype_dict: dict<string> = {}
if exists('g:vim_markdown_fenced_languages')
    for fenced_language in g:vim_markdown_fenced_languages
        var key = matchstr(fenced_language, '[^=]*')
        var val = matchstr(fenced_language, '[^=]*$')
        filetype_dict[key] = val
    endfor
else
    filetype_dict = {
        'c++': 'cpp',
        'viml': 'vim',
        'bash': 'sh',
        'ini': 'dosini',
        'js': 'javascript',
        'jsx': 'javascriptreact',
        'ts': 'typescript',
        'tsx': 'typescriptreact',
    }
endif

def SyntaxInclude(filetype: string): string
    # Include the syntax highlighting of another {filetype}.
    var grouplistname = '@' .. toupper(filetype)
    # Unset the name of the current syntax while including the other syntax
    # because some syntax scripts do nothing when "b:current_syntax" is set
    var syntax_save = ''
    if exists('b:current_syntax')
        syntax_save = b:current_syntax
        unlet b:current_syntax
    endif
    try
        execute 'syntax include ' .. grouplistname .. ' syntax/' .. filetype .. '.vim'
        execute 'syntax include ' .. grouplistname .. ' after/syntax/' .. filetype .. '.vim'
    catch /E484/
        # Ignore missing scripts
    endtry
    # Restore the name of the current syntax
    if syntax_save != ''
        b:current_syntax = syntax_save
    elseif exists('b:current_syntax')
        unlet b:current_syntax
    endif
    return grouplistname
enddef

def MarkdownHighlightSources(force: bool)
    # Syntax highlight source code embedded in notes.
    # Look for code blocks in the current file
    var filetypes: dict<number> = {}
    for text_line in getline(1, '$')
        var ft = matchstr(text_line, '\(`\{3,}\|\~\{3,}\)\s*\zs[0-9A-Za-z_+-]*\ze.*')
        if !empty(ft) && ft !~# '^\d*$'
            filetypes[ft] = 1
        endif
    endfor

    var known: dict<number> = get(b:, 'aichat_known_filetypes', {})
    # set syntax file name included
    var included: dict<number> = get(b:, 'aichat_included_filetypes', {})

    if !force && (known == filetypes || empty(filetypes))
        return
    endif

    # Now we're ready to actually highlight the code blocks.
    var startgroup = 'aichatCodeStart'
    var endgroup = 'aichatCodeEnd'
    for ft in keys(filetypes)
        if force || !has_key(known, ft)
            var filetype = has_key(filetype_dict, ft) ? filetype_dict[ft] : ft
            var group = 'aichatSnippet' .. toupper(substitute(filetype, '[+-]', '_', 'g'))
            var include = ''
            if !has_key(included, filetype)
                include = SyntaxInclude(filetype)
                included[filetype] = 1
            else
                include = '@' .. toupper(filetype)
            endif
            var command_backtick = 'syntax region %s matchgroup=%s start="^\s*`\{3,}\s*%s.*$" matchgroup=%s end="\s*`\{3,}\s*$" keepend contains=%s'
            var command_tilde = 'syntax region %s matchgroup=%s start="^\s*\~\{3,}\s*%s.*$" matchgroup=%s end="\s*\~\{3,}\s*$" keepend contains=%s'
            execute printf(command_backtick, group, startgroup, ft, endgroup, include)
            execute printf(command_tilde, group, startgroup, ft, endgroup, include)
            execute printf('syntax cluster aichatNonListItem add=%s', group)

            known[ft] = 1
        endif
    endfor

    b:aichat_known_filetypes = known
    b:aichat_included_filetypes = included
enddef

def MarkdownHighlightChatOptions(force: bool)
    # use jproperties syntax to highlight chat options
    var filetype = 'jproperties'
    var known: dict<number> = get(b:, 'aichat_known_filetypes', {})
    var included: dict<number> = get(b:, 'aichat_included_filetypes', {})
    if force || !has_key(known, filetype)
        if !has_key(included, filetype)
            SyntaxInclude(filetype)
            included[filetype] = 1
        endif
        syntax region aichatOptions start='\[chat\]' end='^$' contains=@JPROPERTIES
        known[filetype] = 1
    endif
    b:aichat_known_filetypes = known
    b:aichat_included_filetypes = included
enddef

def MarkdownRefreshSyntax(force: bool)
    vim_ai_config.Load()
    MarkdownHighlightSources(force)
    MarkdownHighlightChatOptions(force)
enddef

def MarkdownClearSyntaxVariables()
    if exists('b:aichat_included_filetypes')
        unlet! b:aichat_included_filetypes
    endif
enddef

augroup Aichat
    autocmd! * <buffer>
    autocmd BufWinEnter <buffer> MarkdownRefreshSyntax(true)
    autocmd BufUnload <buffer> MarkdownClearSyntaxVariables()
    autocmd BufWritePost <buffer> MarkdownRefreshSyntax(false)
    autocmd InsertEnter,InsertLeave <buffer> MarkdownRefreshSyntax(false)
    autocmd CursorHold,CursorHoldI <buffer> MarkdownRefreshSyntax(false)
augroup END
