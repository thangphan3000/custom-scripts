" =============================================================================
" General
" =============================================================================
set background=dark
set mouse=a
set laststatus=2
set shortmess+=sI
set termguicolors
set noswapfile
set hlsearch
set shell=zsh
set wrap
set scrolloff=8
set relativenumber
set nofixendofline
set number

" Performance
set history=100
set updatetime=250
set lazyredraw
set synmaxcol=200

" Indenting
set tabstop=2
set shiftwidth=2
set ignorecase
set smartcase
set expandtab
set backspace=start,eol,indent

" Menu code completion
set wildmenu
set completeopt=menuone,noselect

" =============================================================================
" Leader
" =============================================================================
let mapleader = ' '

" =============================================================================
" Netrw
" =============================================================================
let g:netrw_banner   = 0
let g:netrw_liststyle = 3

" =============================================================================
" Keymaps
" =============================================================================

" Insert
inoremap <silent> <C-l> <C-o>A
inoremap <silent> jk    <Esc>

" Visual
vnoremap <silent> <Tab>   >gv
vnoremap <silent> <S-Tab> <gv
xnoremap <silent> <leader>p "_dP

" Normal
nnoremap <silent> <Esc><Esc> :nohlsearch<CR>
nnoremap <silent> <leader>a  ggVG
nnoremap <silent> ss         :split<CR><C-w>w
nnoremap <silent> sv         :vsplit<CR><C-w>w
nnoremap <silent> <C-u>      <C-u>zz
nnoremap <silent> <C-d>      <C-d>zz
nnoremap <silent> <C-h>      <C-w>h
nnoremap <silent> <C-j>      <C-w>j
nnoremap <silent> <C-k>      <C-w>k
nnoremap <silent> <C-l>      <C-w>l
nnoremap <silent> <Tab>      :bnext<CR>
nnoremap <silent> <S-Tab>    :bprev<CR>

" Clipboard (macOS)
if has('mac')
  vnoremap <silent> y   y:call system('pbcopy', @")<CR>
  nnoremap <silent> yy  yy:call system('pbcopy', @")<CR>
  nnoremap <silent> yiw yiw:call system('pbcopy', @")<CR>
  nnoremap <silent> yiW yiW:call system('pbcopy', @")<CR>
endif

" =============================================================================
" FuzzyFinder - two-pane fuzzy file finder and live grep
" No plugins, no external fuzzy binaries: git/find for listing, grep for
" search, Vim's built-in matchfuzzy() (C-implemented) for ranking, and a
" side-by-side syntax-highlighted preview pane.
"   <C-p>  find files      <C-g>  live grep
" In the picker: <C-n>/<C-p> move, <CR> open, <Esc> close,
"                <BS> delete char, <C-w> delete word, <C-u> clear.
" =============================================================================
let s:ff = {}

" Config (override anywhere before use).
let g:fuzzyfinder_preview = get(g:, 'fuzzyfinder_preview', 1)
let g:fuzzyfinder_preview_maxlines = get(g:, 'fuzzyfinder_preview_maxlines', 500)

" Rounded border: [top, right, bottom, left, topleft, topright, botright, botleft]
let s:ff_borderchars = ['─', '│', '─', '│', '╭', '╮', '╯', '╰']
" Dedicated buffer-name dir so preview filetype detection can't collide with
" the user's real open buffers.
let s:ff_preview_dir = '/tmp/.ffpreview'
let s:ff_syntax_ready = 0
let s:ff_has_matchfuzzy = exists('*matchfuzzy')

function! s:ff_reset() abort
  let s:ff = {
        \ 'active': 0,
        \ 'mode': '',
        \ 'root': getcwd(),
        \ 'items': [],
        \ 'filtered': [],
        \ 'query': '',
        \ 'selected': 0,
        \ 'popup_id': -1,
        \ 'preview_id': -1,
        \ 'preview_h': 20,
        \ 'text_w': 40,
        \ 'list_rows': 20,
        \ 'offset': 0,
        \ 'job': v:null,
        \ 'timer': -1,
        \ 'render_timer': -1,
        \ 'preview_timer': -1,
        \ 'max_results': 200,
        \ }
endfunction

" Lazily enable the syntax/filetype engines so the preview can highlight.
function! s:ff_ensure_syntax() abort
  if s:ff_syntax_ready || !g:fuzzyfinder_preview
    return
  endif
  if !exists('g:syntax_on')
    syntax enable
  endif
  filetype on
  let s:ff_syntax_ready = 1
endfunction

" Fuzzy ranking: prefer built-in matchfuzzy() (C, ~1000x faster than Vimscript).
function! s:ff_fallback_score(text, query) abort
  let hay = tolower(a:text)
  let needle = tolower(a:query)
  let score = 0
  let prev_match = -2
  let search_from = 0
  let hay_len = len(hay)
  for qc in split(needle, '\zs')
    let found = stridx(hay, qc, search_from)
    if found == -1
      return -1
    endif
    let score += (found == prev_match + 1) ? 8 : 1
    if found == 0 || hay[found - 1] =~# '[/_\-. ]'
      let score += 3
    endif
    let prev_match = found
    let search_from = found + 1
  endfor
  return score - (hay_len / 10)
endfunction

function! s:ff_filter(items, query) abort
  if a:query ==# ''
    return a:items[0 : s:ff.max_results - 1]
  endif
  if s:ff_has_matchfuzzy
    return matchfuzzy(a:items, a:query, {'limit': s:ff.max_results})
  endif
  let scored = []
  for item in a:items
    let sc = s:ff_fallback_score(item, a:query)
    if sc >= 0
      call add(scored, [sc, item])
    endif
  endfor
  call sort(scored, {a, b -> b[0] - a[0]})
  return map(scored[0 : s:ff.max_results - 1], 'v:val[1]')
endfunction

" Geometry: two side-by-side panes centred on screen.
function! s:ff_layout() abort
  let two_pane = g:fuzzyfinder_preview
  let width = float2nr(&columns * 0.94)
  let height = float2nr(&lines * 0.82)
  let top = (&lines - height) / 2
  let base_col = (&columns - width) / 2 + 1
  let gap = 2
  if two_pane
    let left_fp = (width - gap) / 2
    let right_fp = width - gap - left_fp
  else
    let left_fp = width
    let right_fp = 0
  endif
  let inner_h = height - 2
  return {
        \ 'top': top,
        \ 'inner_h': inner_h,
        \ 'left_col': base_col,
        \ 'left_text': max([10, left_fp - 4]),
        \ 'right_col': base_col + left_fp + gap,
        \ 'right_text': max([10, right_fp - 4]),
        \ 'two_pane': two_pane,
        \ }
endfunction

" Scroll the results window so the selected item stays visible; prompt and
" separator are pinned as lines 1-2, only the results below them scroll.
function! s:ff_adjust_offset() abort
  let rows = max([1, s:ff.list_rows])
  let total = len(s:ff.filtered)
  if s:ff.selected < s:ff.offset
    let s:ff.offset = s:ff.selected
  elseif s:ff.selected >= s:ff.offset + rows
    let s:ff.offset = s:ff.selected - rows + 1
  endif
  let maxoff = max([0, total - rows])
  let s:ff.offset = min([max([0, s:ff.offset]), maxoff])
endfunction

function! s:ff_build_lines() abort
  let inner = s:ff.text_w
  let total = len(s:ff.filtered)
  let cnt = total > 0 ? printf('%d/%d', s:ff.selected + 1, total) : '0/0'
  let head = s:ff.query . '█'
  let pad = inner - strdisplaywidth(head) - strdisplaywidth(cnt)
  let prompt = head . repeat(' ', max([1, pad])) . cnt
  let lines = [prompt, repeat('─', inner)]
  if empty(s:ff.filtered)
    call add(lines, '  (no matches)')
  else
    call s:ff_adjust_offset()
    let last = min([s:ff.offset + s:ff.list_rows, total]) - 1
    for i in range(s:ff.offset, last)
      call add(lines, (i == s:ff.selected ? '> ' : '  ') . s:ff.filtered[i])
    endfor
  endif
  return lines
endfunction

function! s:ff_render() abort
  " A late timer/job callback must not resurrect a closed picker.
  if !s:ff.active
    return
  endif
  if s:ff.popup_id == -1
    let lay = s:ff_layout()
    let s:ff.text_w = lay.left_text
    let s:ff.list_rows = max([1, lay.inner_h - 2])
    let s:ff.popup_id = popup_create(s:ff_build_lines(), {
          \ 'line': lay.top,
          \ 'col': lay.left_col,
          \ 'pos': 'topleft',
          \ 'minwidth': lay.left_text,
          \ 'maxwidth': lay.left_text,
          \ 'minheight': lay.inner_h,
          \ 'maxheight': lay.inner_h,
          \ 'border': [],
          \ 'borderchars': s:ff_borderchars,
          \ 'padding': [0, 1, 0, 1],
          \ 'filter': function('s:ff_on_key'),
          \ 'mapping': 0,
          \ 'wrap': 0,
          \ 'cursorline': 0,
          \ 'zindex': 210,
          \ })
    if lay.two_pane
      let s:ff.preview_h = lay.inner_h
      let s:ff.preview_id = popup_create([], {
            \ 'line': lay.top,
            \ 'col': lay.right_col,
            \ 'pos': 'topleft',
            \ 'minwidth': lay.right_text,
            \ 'maxwidth': lay.right_text,
            \ 'minheight': lay.inner_h,
            \ 'maxheight': lay.inner_h,
            \ 'border': [],
            \ 'borderchars': s:ff_borderchars,
            \ 'padding': [0, 1, 0, 1],
            \ 'mapping': 0,
            \ 'wrap': 0,
            \ 'zindex': 200,
            \ })
    endif
  else
    call popup_settext(s:ff.popup_id, s:ff_build_lines())
  endif
  call s:ff_highlight()
  call s:ff_schedule_preview()
endfunction

function! s:ff_highlight() abort
  if empty(s:ff.filtered)
    call win_execute(s:ff.popup_id, 'call clearmatches()')
    return
  endif
  " clearmatches() first, else matchadd() accumulates one match per render.
  let row = (s:ff.selected - s:ff.offset) + 3
  call win_execute(s:ff.popup_id,
        \ 'call clearmatches() | call matchadd("PmenuSel", "\\%' . row . 'l.*")')
endfunction

function! s:ff_parse(line) abort
  " Grep results look like  path:lnum:text ; file results are bare paths.
  if a:line =~# '^[^:]\+:\d\+:'
    let parts = matchlist(a:line, '^\([^:]\+\):\(\d\+\):')
    return {'path': parts[1], 'lnum': str2nr(parts[2])}
  endif
  return {'path': a:line, 'lnum': 0}
endfunction

function! s:ff_schedule_preview() abort
  if s:ff.preview_id == -1
    return
  endif
  if s:ff.preview_timer != -1
    call timer_stop(s:ff.preview_timer)
  endif
  let s:ff.preview_timer = timer_start(40, {-> s:ff_update_preview()})
endfunction

function! s:ff_update_preview() abort
  let s:ff.preview_timer = -1
  if !s:ff.active || s:ff.preview_id == -1
    return
  endif
  if empty(s:ff.filtered)
    call popup_settext(s:ff.preview_id, ['', '  (no selection)'])
    return
  endif
  let info = s:ff_parse(s:ff.filtered[s:ff.selected])
  let path = info.path
  if !filereadable(path)
    call popup_settext(s:ff.preview_id, ['', '  (not readable: ' . path . ')'])
    return
  endif
  let content = readfile(path, '', g:fuzzyfinder_preview_maxlines)
  call popup_settext(s:ff.preview_id, content)
  " Filetype detection via a collision-free buffer name that keeps the basename.
  let bufname = s:ff_preview_dir . '/' . fnamemodify(path, ':t')
  call win_execute(s:ff.preview_id, 'silent! keepalt file ' . fnameescape(bufname))
  call win_execute(s:ff.preview_id, 'setlocal filetype= | filetype detect')
  " Popups scroll via the 'firstline' property, not normal-mode motions.
  if info.lnum > 0
    let first = max([1, info.lnum - s:ff.preview_h / 2])
    call popup_setoptions(s:ff.preview_id, {'firstline': first})
    call win_execute(s:ff.preview_id,
          \ 'call clearmatches() | call matchadd("Search", "\\%' . info.lnum . 'l.*")')
  else
    call popup_setoptions(s:ff.preview_id, {'firstline': 1})
    call win_execute(s:ff.preview_id, 'call clearmatches()')
  endif
endfunction

function! s:ff_list_files() abort
  if isdirectory(s:ff.root . '/.git')
    let cmd = 'git -C ' . shellescape(s:ff.root) . ' ls-files --cached --others --exclude-standard'
  else
    let cmd = 'find ' . shellescape(s:ff.root) . ' -type f -not -path "*/.git/*"'
  endif
  return systemlist(cmd)
endfunction

function! s:ff_stop_job() abort
  if s:ff.job isnot v:null && job_status(s:ff.job) ==# 'run'
    call job_stop(s:ff.job)
  endif
  let s:ff.job = v:null
endfunction

" Coalesce redraws: many result lines can arrive per event-loop tick.
function! s:ff_schedule_render() abort
  if s:ff.render_timer != -1
    return
  endif
  let s:ff.render_timer = timer_start(30, {-> s:ff_flush_render()})
endfunction

function! s:ff_flush_render() abort
  let s:ff.render_timer = -1
  call s:ff_render()
endfunction

function! s:ff_grep_out(channel, msg) abort
  if !s:ff.active
    return
  endif
  if len(s:ff.filtered) >= s:ff.max_results
    call s:ff_stop_job()
    return
  endif
  call add(s:ff.filtered, a:msg)
  call s:ff_schedule_render()
endfunction

function! s:ff_grep_start(query) abort
  call s:ff_stop_job()
  let s:ff.filtered = []
  if a:query ==# ''
    call s:ff_render()
    return
  endif
  if isdirectory(s:ff.root . '/.git')
    let cmd = ['git', '-C', s:ff.root, 'grep', '-n', '--no-color', '-I', '-e', a:query]
  else
    let cmd = ['grep', '-rn', '--exclude-dir=.git', a:query, s:ff.root]
  endif
  let s:ff.job = job_start(cmd, {
        \ 'out_cb': function('s:ff_grep_out'),
        \ 'in_io': 'null',
        \ })
endfunction

function! s:ff_debounced_grep() abort
  let s:ff.timer = -1
  call s:ff_grep_start(s:ff.query)
endfunction

function! s:ff_query_changed() abort
  let s:ff.selected = 0
  let s:ff.offset = 0
  if s:ff.mode ==# 'files'
    let s:ff.filtered = s:ff_filter(s:ff.items, s:ff.query)
    call s:ff_render()
  else
    let s:ff.filtered = []
    call s:ff_render()
    if s:ff.timer != -1
      call timer_stop(s:ff.timer)
    endif
    let s:ff.timer = timer_start(120, {-> s:ff_debounced_grep()})
  endif
endfunction

function! s:ff_close() abort
  call s:ff_stop_job()
  for t in [s:ff.timer, s:ff.render_timer, s:ff.preview_timer]
    if t != -1
      call timer_stop(t)
    endif
  endfor
  if s:ff.preview_id != -1
    call popup_close(s:ff.preview_id)
  endif
  if s:ff.popup_id != -1
    call popup_close(s:ff.popup_id)
  endif
  call s:ff_reset()
endfunction

function! s:ff_move(delta) abort
  let n = len(s:ff.filtered)
  if n == 0
    return
  endif
  let s:ff.selected = (s:ff.selected + a:delta + n) % n
  call s:ff_render()
endfunction

function! s:ff_open() abort
  if empty(s:ff.filtered) || s:ff.selected >= len(s:ff.filtered)
    call s:ff_close()
    return
  endif
  let info = s:ff_parse(s:ff.filtered[s:ff.selected])
  call s:ff_close()
  execute 'edit' fnameescape(info.path)
  if info.lnum > 0
    execute info.lnum
    normal! zz
  endif
endfunction

function! s:ff_on_key(id, key) abort
  let key = a:key
  if key ==# "\<Esc>" || key ==# "\<C-c>"
    call s:ff_close()
  elseif key ==# "\<CR>"
    call s:ff_open()
  elseif key ==# "\<C-n>" || key ==# "\<Down>"
    call s:ff_move(1)
  elseif key ==# "\<C-p>" || key ==# "\<Up>"
    call s:ff_move(-1)
  elseif key ==# "\<BS>" || key ==# "\<C-h>"
    if len(s:ff.query) > 0
      let s:ff.query = strcharpart(s:ff.query, 0, strchars(s:ff.query) - 1)
      call s:ff_query_changed()
    endif
  elseif key ==# "\<C-w>"
    let s:ff.query = substitute(s:ff.query, '\s*\S\+\s*$', '', '')
    call s:ff_query_changed()
  elseif key ==# "\<C-u>"
    let s:ff.query = ''
    call s:ff_query_changed()
  elseif strchars(key) == 1 && char2nr(key) >= 32
    let s:ff.query .= key
    call s:ff_query_changed()
  endif
  return 1
endfunction

function! s:ff_files() abort
  call s:ff_reset()
  call s:ff_ensure_syntax()
  let s:ff.active = 1
  let s:ff.mode = 'files'
  let s:ff.items = s:ff_list_files()
  let s:ff.filtered = s:ff_filter(s:ff.items, '')
  call s:ff_render()
endfunction

function! s:ff_grep() abort
  call s:ff_reset()
  call s:ff_ensure_syntax()
  let s:ff.active = 1
  let s:ff.mode = 'grep'
  call s:ff_render()
endfunction

nnoremap <silent> <C-p> :<C-u>call <SID>ff_files()<CR>
nnoremap <silent> <C-g> :<C-u>call <SID>ff_grep()<CR>
