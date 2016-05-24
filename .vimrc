" Use .vim on windows instead of _vimfiles
set runtimepath=~/.vim,$VIMRUNTIME

" Default tab settings. Uses 4 spaces instead of a tab.
set expandtab
set tabstop=4
set softtabstop=4
set shiftwidth=4
set backspace=indent,eol,start

set laststatus=2 " Always show status line (airline)

set guioptions-=T " No toolbar
set guioptions-=m " No menu bar
set guioptions-=r " No right hand scrollbar
set guioptions-=L " No left hand scrollbar
set guifont=Source_Code_Pro:h10

set encoding=utf-8
set ff=unix
scriptencoding utf-8
set relativenumber
set number
set ruler
set hidden
set secure
syntax on
colorscheme railscasts

map <leader>k :vsc View.SolutionExplorer<CR>

au BufNewFile,BufRead *.xaml set filetype=xml " Act as if XAML files are XML files.


let g:rooter_patterns = [ '.git', 'units.lua', 'generate.bat' ]

" CTRLP 
let g:ctrlp_working_path_mode = 'a' " controlp must obey rooter
let g:ctrlp_user_command = 'ag --files-with-matches --nocolor -g "" %s'
let g:ctrlp_cache_dir = $HOME . '/.cache/ctrlp'


let g:airline_powerline_fonts = 1
let g:plug_timeout = 1000

let g:ycm_autoclose_preview_window_after_completion = 1
map <C-G> :YcmCompleter GoTo<CR>

call plug#begin()
Plug 'ctrlpvim/ctrlp.vim'
Plug 'nfvs/vim-perforce'
Plug 'vim-airline/vim-airline'
Plug 'airblade/vim-rooter'
Plug 'easymotion/vim-easymotion'
Plug 'Valloric/YouCompleteMe'
call plug#end()
