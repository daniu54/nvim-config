-- multicursor.lua — multiple cursors (multicursor.nvim)
--
-- The VS Code / JetBrains "Alt+j / Alt+k drops another cursor on the line
-- below / above" gesture, in the one implementation that behaves the way the
-- rest of this config expects: the extra cursors are *real cursors*, not a
-- macro replayed over a set of lines. Every normal-mode command works on all
-- of them at once (`i`, `A`, `ciw`, `dd`, `.`, counts, motions, registers,
-- undo, completion, snippets), so nothing has to be learned twice.
--
-- The flow is: <A-j>/<A-k> to place cursors, then vim as usual, then <Esc>
-- to collapse back to one cursor.
--
-- Not vim-visual-multi (the older, better-known plugin): that one runs its
-- own modal layer over the buffer with its own semantics for most keys, which
-- is exactly the "behaves like a normal cursor, no?" property being bought
-- here.
local ok, mc = pcall(require, 'multicursor-nvim')
if not ok then return end

mc.setup()

local function set(modes, lhs, rhs, desc)
  vim.keymap.set(modes, lhs, rhs, { desc = desc, silent = true })
end

local nx = { 'n', 'x' }

-- Placing cursors. <A-S-j>/<A-S-k> leave a gap: they move the *next* cursor
-- down/up a line without adding one where you are, for the "every other line"
-- case.
set(nx, '<A-j>', function() mc.lineAddCursor(1) end, 'Multicursor: add a cursor below')
set(nx, '<A-k>', function() mc.lineAddCursor(-1) end, 'Multicursor: add a cursor above')
set(nx, '<A-S-j>', function() mc.lineSkipCursor(1) end, 'Multicursor: skip a line downwards')
set(nx, '<A-S-k>', function() mc.lineSkipCursor(-1) end, 'Multicursor: skip a line upwards')

-- Placing cursors by content instead of by position — VS Code's Ctrl+D.
-- <A-n> takes the word under the cursor (or the visual selection) and puts a
-- cursor on its next occurrence; <A-s> passes one over.
set(nx, '<A-n>', function() mc.matchAddCursor(1) end, 'Multicursor: add a cursor on the next match of the word/selection')
set(nx, '<A-N>', function() mc.matchAddCursor(-1) end, 'Multicursor: add a cursor on the previous match')
set(nx, '<A-s>', function() mc.matchSkipCursor(1) end, 'Multicursor: skip the next match')
set(nx, '<A-S>', function() mc.matchSkipCursor(-1) end, 'Multicursor: skip the previous match')
set(nx, '<A-m>', mc.matchAllAddCursors, 'Multicursor: a cursor on every match of the word/selection in the buffer')

-- Freeze the extra cursors: only the main one moves, so you can walk it
-- somewhere else (or add another) without dragging the rest along. <A-q>
-- again — or <Esc> — wakes them up.
set(nx, '<A-q>', mc.toggleCursor, 'Multicursor: freeze/unfreeze the other cursors')

-- <Esc> is the way out, which makes it easy to lose a hard-won set of
-- cursors to a stray keypress. This puts them back.
set('n', '<A-g>', mc.restoreCursors, 'Multicursor: restore the cursors just cleared')

-- Mouse: ctrl+click adds/removes a cursor, ctrl+drag adds a selection.
set('n', '<C-LeftMouse>', mc.handleMouse, 'Multicursor: add/remove a cursor at the click')
set('n', '<C-LeftDrag>', mc.handleMouseDrag, 'Multicursor: drag out a cursor selection')
set('n', '<C-LeftRelease>', mc.handleMouseRelease, 'Multicursor: finish a dragged cursor selection')

-- A keymap layer is only mapped while cursors actually exist, so these keys
-- keep their normal meaning the rest of the time. That is what lets <Esc>
-- stay <Esc>.
mc.addKeymapLayer(function(layerSet)
  -- Which cursor is the "main" one (the one the others follow, and the one
  -- the view scrolls to).
  layerSet(nx, '<A-,>', mc.prevCursor, { desc = 'Multicursor: make the previous cursor the main one' })
  layerSet(nx, '<A-.>', mc.nextCursor, { desc = 'Multicursor: make the next cursor the main one' })

  layerSet(nx, '<A-x>', mc.deleteCursor, { desc = 'Multicursor: delete the main cursor' })

  -- One key, two steps, in the order you want them: with the cursors frozen
  -- (<A-q>) the first <Esc> wakes them up, and the next collapses back to a
  -- single cursor.
  layerSet('n', '<Esc>', function()
    if not mc.cursorsEnabled() then
      mc.enableCursors()
    else
      mc.clearCursors()
    end
  end, { desc = 'Multicursor: unfreeze, else collapse to one cursor' })
end)
