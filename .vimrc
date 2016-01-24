" Use .vim on windows instead of _vimfiles
set runtimepath=~/.vim,$VIMRUNTIME

" Default tab settings. Uses 4 spaces instead of a tab.
set expandtab
set tabstop=4
set shiftwidth=4

set laststatus=2 " Always show status line (airline)

set guioptions-=T " No toolbar
set guioptions-=m " No menu bar
set guioptions-=r " No right hand scrollbar
set guioptions-=L " No left hand scrollbar
set guifont=Source_Code_Pro:h10:cANSI

set nocompatible
set relativenumber
set number
set ruler
set hidden
syntax on
colorscheme railscasts

execute pathogen#infect()

