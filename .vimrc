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
set guifont=Source_Code_Pro:h10

set encoding=utf-8
scriptencoding utf-8
set relativenumber
set number
set ruler
set hidden
set exrc " .vimrc in project folder
set secure
syntax on
colorscheme railscasts

let g:rooter_patterns = [ '.git', 'units.lua' ]
let g:airline_powerline_fonts = 1

call plug#begin()
Plug 'tpope/vim-sensible'
Plug 'ctrlpvim/ctrlp.vim'
Plug 'nfvs/vim-perforce'
Plug 'vim-airline/vim-airline'
Plug 'airblade/vim-rooter'
Plug 'Valloric/YouCompleteMe'
call plug#end()
