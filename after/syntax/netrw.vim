" Gray out dotfiles/dotdirs in netrw. Match the ENTIRE line so our group
" owns all of it and netrw's partial syntax groups can't split the color.
"
" Tree view lines: '| | .bashrc'  (ASCII pipe + spaces before name)
" Thin view lines: '.bashrc'
" Symlink lines:   '.zshrc.claude@  -> /path/to/target'
"
" Dir pattern requires trailing / and is longer → wins the tie-break over
" the file pattern when both could start at the same position.

syn match NetrwDotFile '^[| ]*\.[^./ ][^ /]*\(  ->.*\)\?$'  containedin=ALL
syn match NetrwDotDir  '^[| ]*\.[^./ ][^ ]*/$'               containedin=ALL
