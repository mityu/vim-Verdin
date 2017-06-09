" FIXME: CR to close popup and break at once

" script local variables {{{
let s:const = Verdin#constants#distribute()
let s:lib = Verdin#lib#distribute()
let s:FUNCABBR = printf('^%s([^)]*)$', s:const.FUNCNAME)
let s:FUNCARG = printf('^%s(\zs[^)]*\ze)$', s:const.FUNCNAME)
function! s:SID() abort
  return matchstr(expand('<sfile>'), '<SNR>\zs\d\+\ze_SID$')
endfunction
let s:SID = printf("\<SNR>%s_", s:SID())
delfunction s:SID
let s:VerdinInsertKet = s:SID . '(VerdinInsertKet)'
inoremap <silent> <SID>(VerdinInsertKet) <C-r>=<SID>VerdinInsertKet()<CR>
cnoremap <silent> <SID>(VerdinInsertKet) <Nop>
nnoremap <silent> <SID>(VerdinInsertKet) a)<Esc>
function! s:VerdinInsertKet() abort
  let Completer = Verdin#Completer#get()
  let pat = printf('\m\%%%dl%s[^)]*\%%#%s$', Completer.last.lnum, s:lib.escape(v:completed_item.word), s:lib.escape(Completer.last.postcursor))
  if search(pat, 'bcn', Completer.last.lnum)
    return ")\<C-g>U\<Left>"
  endif
  return ''
endfunction
"}}}

function! Verdin#Completer#new(Dictionaries) abort "{{{
  return s:Completer(a:Dictionaries)
endfunction
"}}}
function! Verdin#Completer#get(...) abort "{{{
  let bufnr = get(a:000, 0, bufnr('%'))
  let bufinfo = get(getbufinfo(bufnr), 0, {})
  if bufinfo == {}
    echoerr 'Verdin: Invalid bufnr is given for Verdin#Completer#get()'
  endif

  if !has_key(bufinfo.variables, 'Verdin')
    let bufinfo.variables.Verdin = {}
  endif
  if !has_key(bufinfo.variables.Verdin, 'Completer')
    let Dictionaries = Verdin#basedict#{&l:filetype}#distribute()
    let bufinfo.variables.Verdin.Completer = s:Completer(Dictionaries)
  endif
  return bufinfo.variables.Verdin.Completer
endfunction
"}}}

" Completer object {{{
let s:Completer = {
      \   'shelf': {},
      \   'candidatelist': [],
      \   'fuzzycandidatelist': [],
      \   'clock': Verdin#clock#new(),
      \   'savedoptions': {},
      \   'is': {
      \     'in_completion': v:false,
      \     'lazyredraw_changed': v:false,
      \   },
      \   'last': {
      \     'lnum': 0,
      \     'col': 0,
      \     'line': '',
      \     'precursor': '',
      \     'postcursor': '',
      \   },
      \ }
let s:CURRENTLNUM = 0
let s:CURRENTCOL = 0
let s:CURRENTLINE = ''
function! s:Completer.startcol(...) dict abort "{{{
  let giveupifshort = get(a:000, 0, v:false)
  let fuzzymatch = s:lib.getoption('fuzzymatch')
  let s:CURRENTLNUM = line('.')
  let s:CURRENTCOL = col('.')
  let s:CURRENTLINE = getline('.')
  let precursor = s:CURRENTCOL == 1 ? '' : s:CURRENTLINE[: s:CURRENTCOL-2]
  let postcursor = s:CURRENTLINE[s:CURRENTCOL-1 :]
  let self.last.lnum = s:CURRENTLNUM
  let self.last.col = s:CURRENTCOL
  let self.last.line = s:CURRENTLINE
  let self.last.precursor = precursor
  let self.last.postcursor = postcursor
  let self.candidatelist = []
  let self.fuzzycandidatelist = []
  let minstartcol = 1/0
  let startcol = minstartcol
  for Dictionary in values(self.shelf)
    let [startcol, candidate, fuzzycandidate]
          \ = s:lookup(Dictionary, precursor, minstartcol, giveupifshort, fuzzymatch)
    if startcol < 0 || startcol > minstartcol
      continue
    endif
    if startcol < minstartcol
      let minstartcol = startcol
      let self.candidatelist = []
      let self.fuzzycandidatelist = []
    endif
    call add(self.candidatelist, candidate)
    call add(self.fuzzycandidatelist, fuzzycandidate)
  endfor
  if minstartcol == 1/0
    return -1
  endif
  call filter(self.candidatelist, 'v:val != {}')
  call filter(self.fuzzycandidatelist, 'v:val != {}')
  let base = s:CURRENTCOL == 1 ? '' : s:CURRENTLINE[minstartcol : s:CURRENTCOL-2]
  let self.fuzzycandidatelist = s:flatten(self.fuzzycandidatelist, base)
  return minstartcol
endfunction
"}}}
function! s:Completer.match(base) dict abort "{{{
  if self.candidatelist == []
    return []
  endif

  call sort(self.candidatelist, {a, b -> b.priority - a.priority})
  let pattern = '\m^' . s:lib.escape(a:base)
  let candidatelist = []
  let filterlist = [['v:val.__text__ =~# pattern', 'v:val =~# pattern'],
                  \ ['v:val.__text__ =~? pattern && v:val.__text__ !~# pattern', 'v:val =~? pattern && v:val !~# pattern']]
  for [filter, wordfilter] in filterlist
    for candidate in self.candidatelist
      if candidate.itemlist == []
        continue
      endif
      if type(candidate.itemlist[0]) == v:t_dict
        let candidatelist += filter(copy(candidate.itemlist), filter)
      else
        let words = filter(copy(candidate.itemlist), wordfilter)
        let candidatelist += s:capitalize(words, a:base)
      endif
    endfor
  endfor
  return candidatelist
endfunction
"}}}
let s:MEMO_fuzzymatch = {}
function! s:Completer.fuzzymatch(base, ...) dict abort "{{{
  if self.fuzzycandidatelist == []
    return []
  endif

  let timelimit = self.clock.elapsed() + get(a:000, 0, 500)
  let nbase = strchars(a:base)
  let s:MEMO_fuzzymatch = {}
  let candidatelist = []
  while self.fuzzycandidatelist != [] && self.clock.elapsed() < timelimit
    let item = self.fuzzycandidatelist[0]
    let __text__ = s:lib.__text__(item)
    let difflen = strchars(__text__) - nbase
    if a:base ==? __text__ || difflen < -2 || (type(item) == v:t_dict && get(item, '__delimitermatch__', 0))
      call remove(self.fuzzycandidatelist, 0)
      continue
    endif
    let d = s:strcmp(a:base, strcharpart(__text__, 0, nbase))
    if d >= s:const.FUZZYMATCHTHRESHOLD
      call add(candidatelist, s:fuzzyitem(item, a:base, d, difflen))
    endif
    call remove(self.fuzzycandidatelist, 0)
  endwhile
  return candidatelist
endfunction
"}}}
function! s:Completer.modify(candidatelist, ...) dict abort "{{{
  let modifiers = get(a:000, 0, ['braket', 'snip'])
  for modifier in modifiers
    if match(modifier, '\m\C^snip$') > -1
      let postcursor = matchstr(self.last.postcursor, '^\k\+\>')
      call s:addsnippeditems(a:candidatelist, postcursor, 0)
    elseif match(modifier, '\m\C^braket$') > -1
      call s:autobrainsert(a:candidatelist)
    endif
  endfor
  return a:candidatelist
endfunction
"}}}
function! s:Completer.complete(startcol, itemlist) dict abort "{{{
  if self.savedoptions == {}
    let self.savedoptions.completeopt = &completeopt
  endif
  set completeopt=menuone,noselect,noinsert
  let Event = Verdin#Event#get()
  call Event.pauseautocomplete()

  " NOTE: It seems 'CompleteDone' event is triggered even inside complete() function.
  let self.is.in_completion = v:true
  call complete(a:startcol+1, a:itemlist)
  let self.is.in_completion = v:false
endfunction
"}}}
function! s:Completer.aftercomplete(event, autocomplete) dict abort "{{{
  if a:event ==# 'CompleteDone' && get(v:completed_item, 'abbr', '') =~# s:FUNCABBR
    call s:autoketinsert(v:completed_item)
  endif
  if !a:autocomplete
    return
  endif
  if a:event ==# 'InsertCharPre' && pumvisible()
    " refresh popup always
    call feedkeys("\<C-e>", 'in')
  endif
  if self.savedoptions != {} && !self.is.in_completion
    let &completeopt = self.savedoptions.completeopt
    let self.savedoptions = {}
    let Event = Verdin#Event#get()
    call Event.startautocomplete()
  endif
endfunction
"}}}
function! s:Completer.addDictionary(name, new) dict abort "{{{
  let self.shelf[a:name] = a:new
endfunction
"}}}
function! s:Completer.dropduplicates(wordlist, namelist) dict abort "{{{
  for name in a:namelist
    call filter(a:wordlist, 'count(self.shelf[name]["wordlist"], v:val) == 0')
  endfor
  return a:wordlist
endfunction
"}}}
let s:NOTHING_FOUND = [-1, {}, {}]
function! s:lookup(Dictionary, precursor, minstartcol, giveupifshort, fuzzymatch) abort  "{{{
  if a:Dictionary == {}
    return s:NOTHING_FOUND
  endif

  let candidate = {}
  let candidate.itemlist = []
  let fuzzycandidate = {}
  let notyetmatched = v:true
  let savedstartcol = -1
  for condition in a:Dictionary.conditionlist
    let [matched, str] = s:matchstr(a:precursor, condition.cursor_at)
    if !matched || (a:giveupifshort && strchars(str) < a:Dictionary.indexlen) || s:cursor_not_at(condition)
      continue
    endif
    let startcol = s:CURRENTCOL - strlen(str) - 1
    if startcol > a:minstartcol
      continue
    endif

    if a:fuzzymatch && notyetmatched
      let fuzzycandidate = a:Dictionary.index
      let savedstartcol = startcol
      let notyetmatched = v:false
    endif

    let c = strcharpart(str, 0, a:Dictionary.indexlen)
    let escaped_c = '^' . s:lib.escape(c)
    if has_key(a:Dictionary.index, c)
      let keys = [c] + filter(keys(a:Dictionary.index), 'v:val =~? escaped_c && v:val !=# c')
    else
      let keys = filter(keys(a:Dictionary.index), 'v:val =~? escaped_c')
    endif

    for key in keys
      let candidate.itemlist += a:Dictionary.index[key]
    endfor
    if candidate.itemlist != []
      let candidate.priority = get(condition, 'priority', 0)
      return [startcol, candidate, fuzzycandidate]
    endif
  endfor
  if savedstartcol >= 0 && savedstartcol <= a:minstartcol
    return [savedstartcol, {}, fuzzycandidate]
  endif
  return s:NOTHING_FOUND
endfunction
"}}}
function! s:matchstr(precursor, pat) abort "{{{
  let [lnum, col] = searchpos(a:pat, 'bcnW', s:CURRENTLNUM)
  if lnum != 0
    return [v:true, a:precursor[col-1 :]]
  endif
  return  [v:false, '']
endfunction
"}}}
function! s:cursor_not_at(condition) abort "{{{
  let cursor_not_at = get(a:condition, 'cursor_not_at', '')
  return cursor_not_at !=# '' && (search(cursor_not_at, 'bcnW', s:CURRENTLNUM) != 0 || search(cursor_not_at, 'cn', s:CURRENTLNUM) != 0)
endfunction
"}}}
function! s:capitalize(words, base) abort "{{{
  if a:base !~# '^\u'
    return a:words
  endif
  return map(a:words, 'substitute(v:val, ''^\(\l\)\(.*\)'', ''\u\1\2'', "")')
endfunction
"}}}
function! s:addsnippeditems(candidatelist, postcursor, ...) abort "{{{
  if a:postcursor ==# ''
    return a:candidatelist
  endif

  let dup = get(a:000, 0, 1)
  let pattern = '\m\C' . s:lib.escape(a:postcursor) . '$'
  let i = len(a:candidatelist) - 1
  while i >= 0
    let candidate = a:candidatelist[i]
    let word = s:lib.word(candidate)
    let idx = match(word, pattern)
    if idx > 0
      if type(candidate) == v:t_dict
        let snipped = deepcopy(candidate)
        let snipped.word = snipped.word[: idx-1]
        let snipped.menu .= ' snipped'
        let snipped.dup = dup
        if !has_key(snipped, 'abbr')
          let snipped.abbr = candidate.word
        endif
        let entire = deepcopy(candidate)
        let entire.menu .= ' entire'
        let entire.dup = dup
      else
        let snipped = {'word': candidate[: idx-1], 'abbr': candidate,
                    \  'menu': 'snipped', 'dup': dup}
        let entire = {'word': candidate, 'menu': 'entire', 'dup': dup}
      endif
      call remove(a:candidatelist, i)
      call insert(a:candidatelist, entire, i)
      call insert(a:candidatelist, snipped, i)
    endif
    let i -= 1
  endwhile
  return a:candidatelist
endfunction
"}}}
function! s:is_started() abort "{{{
  return exists('b:Verdin')
endfunction
"}}}
function! s:flatten(candidatelist, base) abort "{{{
  let nbase = strchars(a:base)
  if nbase < 3
    return []
  endif

  let similarlist = s:similarlist(a:candidatelist, a:base)
  let flattened = []
  for [_, itemlist] in sort(similarlist, {a, b -> a[0] - b[0]})
    let flattened += itemlist
  endfor
  return flattened
endfunction
"}}}
function! s:similarlist(candidatelist, base) abort "{{{
  let pat = join(['\m^\%(', strcharpart(a:base, 0, 1), '\|', substitute(a:base, '\m^\(.\)\(.\).*', '\2\1', ''), '\)'], '')
  let similarlist = []
  for candidate in a:candidatelist
    for key in filter(keys(candidate), 'v:val =~? pat')
      let n = strchars(key)
      let shortbase = strcharpart(a:base, 0, n)
      if n <= 2
        let d = shortbase ==? key ? 0 : 1
        call add(similarlist, [d, copy(candidate[key])])
        continue
      endif
      let threshold = s:lib.DL_threshold(n)
      let d = s:lib.Damerau_Levenshtein_distance(shortbase, key, threshold)
      if d <= threshold
        call add(similarlist, [d, copy(candidate[key])])
      endif
    endfor
  endfor
  return similarlist
endfunction
"}}}
function! s:fuzzyitem(item, base, score, difflen) abort "{{{
  let itemtype = type(a:item)
  let fuzzymenu = ' *fuzzy*'
  if itemtype == v:t_dict
    let candidate = deepcopy(a:item)
    if has_key(candidate, 'menu')
      let candidate.menu .= fuzzymenu
    else
      let candidate.menu = fuzzymenu
    endif
    let candidate.dup = 0
    let candidate.__text__ = a:base
    let candidate.__score__ = a:score
    let candidate.__difflen__ = a:difflen
  elseif itemtype == v:t_string
    let candidate = {'word': a:item, 'menu': fuzzymenu, 'dup': 0,
                  \  '__text__': a:base, '__score__': a:score, '__difflen__': a:difflen}
  endif
  return candidate
endfunction
"}}}
function! s:strcmp(base, text) abort "{{{
  if has_key(s:MEMO_fuzzymatch, a:text)
    let d = s:MEMO_fuzzymatch[a:text]
  else
    let d = s:lib.Jaro_Winkler_distance(a:base, a:text)
    let s:MEMO_fuzzymatch[a:text] = d
  endif
  return d
endfunction
"}}}
function! s:autobrainsert(candidatelist) abort "{{{
  let autobraketinsert = s:lib.getoption('autobraketinsert')
  if autobraketinsert
    for i in range(len(a:candidatelist))
      let candidate = a:candidatelist[i]
      if type(candidate) == v:t_dict && get(candidate, '__func__', v:false)
        let new = copy(candidate)
        if matchstr(candidate.abbr, s:FUNCARG) ==# ''
          let new.word = candidate.word . '()'
        else
          let new.word = candidate.word . '('
        endif
        call remove(a:candidatelist, i)
        call insert(a:candidatelist, new, i)
      endif
    endfor
  endif
endfunction
"}}}
function! s:autoketinsert(item) abort "{{{
  let autobraketinsert = s:lib.getoption('autobraketinsert')
  if autobraketinsert == 2
    if matchstr(a:item.abbr, s:FUNCARG) !=# ''
      call feedkeys(s:VerdinInsertKet, 'im')
    endif
  endif
endfunction
"}}}

function! s:Completer(Dictionaries) abort
  let Completer = deepcopy(s:Completer)
  let Completer.shelf = copy(a:Dictionaries)
  return Completer
endfunction
"}}}

" vim:set ts=2 sts=2 sw=2 tw=0:
" vim:set foldmethod=marker: commentstring="%s:
