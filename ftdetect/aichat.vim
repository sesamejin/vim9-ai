vim9script

augroup aichat_ftdetect
  autocmd!
  autocmd BufNewFile,BufRead *.aichat setfiletype aichat
augroup END
