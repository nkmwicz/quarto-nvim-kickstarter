return {

  { -- requires plugins in lua/plugins/treesitter.lua and lua/plugins/lsp.lua
    -- for complete functionality (language features)
    'quarto-dev/quarto-nvim',
    ft = { 'quarto' },
    dev = false,
    opts = {
      codeRunner = {
        enabled = true,
        default_method = 'molten',
      },
    },
    dependencies = {
      -- for language features in code cells
      -- configured in lua/plugins/lsp.lua and
      -- added as a nvim-cmp source in lua/plugins/completion.lua
      'jmbuhr/otter.nvim',
    },
    keys = {
      { '<leader>mc', function() require('quarto.runner').run_cell() end, desc = 'molten run [c]ell (cursor)' },
      { '<leader>ma', function() require('quarto.runner').run_above() end, desc = 'molten run [a]bove' },
      { '<leader>mb', function() require('quarto.runner').run_below() end, desc = 'molten run [b]elow' },
      { '<leader>mA', function() require('quarto.runner').run_all() end, desc = 'molten run [A]ll' },
      { '<leader>ml', function() require('quarto.runner').run_line() end, desc = 'molten run [l]ine' },
    },
  },

  { -- directly open ipynb files as quarto docuements
    -- and convert back behind the scenes
    'GCBallesteros/jupytext.nvim',
    opts = {
      custom_language_formatting = {
        python = {
          extension = 'qmd',
          style = 'quarto',
          force_ft = 'quarto',
        },
      },
    },
  },

  { -- send code from python/qmd documents to a terminal or REPL
    -- like ipython, bash
    'jpalardy/vim-slime',
    dev = false,
    init = function()
      vim.b['quarto_is_python_chunk'] = false
      Quarto_is_in_python_chunk = function()
        require('otter.tools.functions').is_otter_language_context 'python'
      end

      vim.cmd [[
      let g:slime_dispatch_ipython_pause = 100
      function SlimeOverride_EscapeText_quarto(text)
      call v:lua.Quarto_is_in_python_chunk()
      if exists('g:slime_python_ipython') && len(split(a:text,"\n")) > 1 && b:quarto_is_python_chunk
      return ["%cpaste -q\n", g:slime_dispatch_ipython_pause, a:text, "--", "\n"]
      else
      return [a:text]
      end
      endfunction
      ]]

      vim.g.slime_target = 'neovim'
      vim.g.slime_no_mappings = true
      vim.g.slime_python_ipython = 1
    end,
    config = function()
      vim.g.slime_input_pid = false
      vim.g.slime_suggest_default = true
      vim.g.slime_menu_config = false
      vim.g.slime_neovim_ignore_unlisted = true

      -- vim-slime's neovim target rebuilds its channel list by scanning every
      -- buffer and calling jobpid() on each terminal's &channel. If any
      -- terminal buffer's job has already died (e.g. an exited REPL whose
      -- window was never closed), jobpid() throws E900: Invalid channel id
      -- and aborts the whole scan, so even a live terminal can't be found.
      -- Force-load the vendor autoload file once, then override just that
      -- one function to skip dead channels instead of erroring.
      vim.cmd [[
      runtime autoload/slime/targets/neovim.vim
      function! slime#targets#neovim#SlimeAddChannel(buf_in) abort
        let buf_in = str2nr(a:buf_in)
        if slime#config#resolve("neovim_ignore_unlisted") && !buflisted(buf_in)
          return
        endif
        let jobid = getbufvar(buf_in, "&channel")
        if jobid == ""
          return
        endif
        try
          let job_pid = jobpid(jobid)
        catch /E900/
          return
        endtry
        if !exists("g:slime_last_channel")
          let g:slime_last_channel = [{'jobid': jobid, 'pid': job_pid, 'bufnr': buf_in}]
        else
          call add(g:slime_last_channel, {'jobid': jobid, 'pid': job_pid, 'bufnr': buf_in})
        endif
      endfunction
      ]]

      local function mark_terminal()
        local job_id = vim.b.terminal_job_id
        vim.print('job_id: ' .. job_id)
      end

      local function set_terminal()
        vim.fn.call('slime#config', {})
      end
      vim.keymap.set('n', '<leader>cm', mark_terminal, { desc = '[m]ark terminal' })
      vim.keymap.set('n', '<leader>cs', set_terminal, { desc = '[s]et terminal' })
    end,
  },

  { -- paste an image from the clipboard or drag-and-drop
    'HakonHarnes/img-clip.nvim',
    event = 'BufEnter',
    ft = { 'markdown', 'quarto', 'latex' },
    opts = {
      default = {
        dir_path = 'img',
      },
      filetypes = {
        markdown = {
          url_encode_path = true,
          template = '![$CURSOR]($FILE_PATH)',
          drag_and_drop = {
            download_images = false,
          },
        },
        quarto = {
          url_encode_path = true,
          template = '![$CURSOR]($FILE_PATH)',
          drag_and_drop = {
            download_images = false,
          },
        },
      },
    },
    config = function(_, opts)
      require('img-clip').setup(opts)
      vim.keymap.set('n', '<leader>ii', ':PasteImage<cr>', { desc = 'insert [i]mage from clipboard' })
    end,
  },

  { -- preview equations
    'jbyuki/nabla.nvim',
    keys = {
      { '<leader>qm', ':lua require"nabla".toggle_virt()<cr>', desc = 'toggle [m]ath equations' },
    },
  },

  {
    'benlubas/molten-nvim',
    enabled = true,
    build = ':UpdateRemotePlugins',
    init = function()
      vim.g.molten_image_provider = 'image.nvim'
      vim.g.molten_output_win_max_height = 20
      vim.g.molten_auto_open_output = false
    end,
    keys = {
      { '<leader>mi', ':MoltenInit<cr>', desc = '[m]olten [i]nit' },
      {
        '<leader>mv',
        ':<C-u>MoltenEvaluateVisual<cr>',
        mode = 'v',
        desc = 'molten eval visual',
      },
      { '<leader>mr', ':MoltenReevaluateCell<cr>', desc = 'molten re-eval cell' },
    },
  },
}
