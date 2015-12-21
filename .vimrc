" Needed so that conemu understands vim color schemes correctly
set term=xterm
set t_Co=256
let &t_AB="\e[48;5;%dm"
let &t_AF="\e[38;5;%dm"


set expandtab
set tabstop=4

set laststatus=2


set nocompatible
set number
set ruler
set hidden
syntax on
colorscheme onedark

let g:airline#extensions#tabline#enabled = 1

execute pathogen#infect()

