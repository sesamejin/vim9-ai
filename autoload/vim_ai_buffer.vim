vim9script

# Helpers to insert and delete text without relying on Normal mode commands.
#
# The previous implementation typed the response with `:normal! a...`, which
# depends on the mode Vim is left in by the preceding `:normal!` command and
# breaks on multi line chunks. The functions below keep an explicit "insertion
# point" (line number and 0 based byte offset) and update the buffer directly.

const max_column = 2147483647

export def Cursor(lnum: number, column: number): void
    cursor(max([1, lnum]), max([1, column]))
enddef

# Starts a new insertion at `lnum`, byte offset `column` (0 based). Inserted
# text is placed in front of the byte at that offset, exactly like Insert mode.
export def InsertState(lnum: number, column: number): dict<any>
    return {lnum: max([1, lnum]), column: max([0, column])}
enddef

# Inserts `text` at the insertion point and moves the insertion point behind
# it. Newlines in `text` split the current line.
export def InsertText(state: dict<any>, text: string): void
    var lines = split(text, "\n", true)
    var lnum: number = min([state.lnum, line('$')])
    var column: number = state.column
    var current = getline(lnum)
    if column > len(current)
        column = len(current)
    endif
    var head = strpart(current, 0, column)
    var tail = strpart(current, column)

    if len(lines) == 1
        setline(lnum, head .. lines[0] .. tail)
        state.lnum = lnum
        state.column = column + len(lines[0])
    else
        setline(lnum, head .. lines[0])
        append(lnum, lines[1 : -2] + [lines[-1] .. tail])
        state.lnum = lnum + len(lines) - 1
        state.column = len(lines[-1])
    endif

    Cursor(state.lnum, state.column + 1)
enddef

# Appends lines at the end of the buffer and returns the insertion point.
export def AppendLines(lines: list<string>): dict<any>
    var last = line('$')
    append(last, lines)
    return InsertState(last + 1, 0)
enddef

# Deletes the given line range, a placeholder line takes its place so that the
# following text starts on its own line (this is what `c` on a line wise
# selection does).
export def DeleteLines(firstline: number, lastline: number): dict<any>
    var start = max([1, min([firstline, line('$')])])
    var end = max([start, min([lastline, line('$')])])
    deletebufline(bufnr('%'), start, end)
    append(start - 1, [''])
    return InsertState(start, 0)
enddef

# True when the last visual selection was line wise. Vim stores `'>` at the
# maximum column for line wise selections.
export def IsLinewiseSelection(): bool
    return getpos("'>")[2] >= max_column
enddef

# Deletes the last visual selection (character or line wise) and returns the
# insertion point where the replacement text belongs. This is the equivalent of
# running `c` on the selection.
export def DeleteVisualSelection(): dict<any>
    var [line_start, column_start] = getpos("'<")[1 : 2]
    var [line_end, column_end] = getpos("'>")[1 : 2]

    if line_start <= 0 || line_end <= 0
        return InsertState(line('.'), 0)
    endif

    if IsLinewiseSelection()
        return DeleteLines(line_start, line_end)
    endif

    var first = strpart(getline(line_start), 0, max([0, column_start - 1]))
    # first byte that stays behind the selection, depends on the `selection` option
    var cut = &selection ==# 'inclusive' ? column_end : column_end - 1
    var last = strpart(getline(line_end), max([0, cut]))

    setline(line_start, first .. last)
    if line_end > line_start
        deletebufline(bufnr('%'), line_start + 1, line_end)
    endif
    return InsertState(line_start, len(first))
enddef

# Inserts `text` one chunk at a time, joining the undo blocks so that a single
# `u` reverts the whole response.
export def InsertChunks(state: dict<any>, chunks: list<string>): string
    var inserted = ''
    for chunk in chunks
        if chunk == ''
            continue
        endif
        InsertText(state, chunk)
        try
            undojoin
        catch
            # `undojoin` fails right after an undo, that is fine
        endtry
        inserted ..= chunk
        redraw
    endfor
    return inserted
enddef
