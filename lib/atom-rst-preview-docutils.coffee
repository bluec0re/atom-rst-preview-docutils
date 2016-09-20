url = require 'url'
fs = require 'fs-plus'

RestructeredTextPreviewView = null
renderer = null

isRestructeredTextPreviewView = (object) ->
    RestructeredTextPreviewView ?= require './atom-rst-preview-docutils-view'
    object instanceof RestructeredTextPreviewView

module.exports = AtomRstPreviewDocutils =

  activate: ->
    if parseFloat(atom.getVersion()) < 1.7
      atom.deserializers.add
        name: 'RestructeredTextPreviewView'
        deserialize: module.exports.createRstPreviewView.bind(module.exports)

    atom.commands.add 'atom-workspace',
      'atom-rst-preview-docutils:toggle': =>
        @toggle()
      'atom-rst-preview-docutils:copy-html': =>
        @copyHtml()

    atom.workspace.addOpener (uriToOpen) =>
      [protocol, path] = uriToOpen.split('://')
      return unless protocol is 'atom-rst-preview-docutils'

      try
        path = decodeURI(path)
      catch
        return

      if path.startsWith 'editor/'
        @createRstPreviewView(editorId: path.substring(7))
      else
        @createRstPreviewView(filePath: path)

    previewFile = @previewFile.bind(this)
    atom.commands.add '.tree-view .file .name[data-name$=\\.rst]', 'atom-rst-preview-docutils:preview-file', previewFile

  createRstPreviewView: (state) ->
    if state.editorId or fs.isFileSync(state.filePath)
      RestructeredTextPreviewView ?= require './atom-rst-preview-docutils-view'
      new RestructeredTextPreviewView(state)

  toggle: ->
    if isRestructeredTextPreviewView(atom.workspace.getActivePaneItem())
      atom.workspace.destroyActivePaneItem()
      return

    editor = atom.workspace.getActiveTextEditor()
    return unless editor?

    grammars = atom.config.get('atom-rst-preview-docutils.grammars') ? []
    return unless editor.getGrammar().scopeName in grammars

    @addPreviewForEditor(editor) unless @removePreviewForEditor(editor)

  uriForEditor: (editor) ->
    "atom-rst-preview-docutils://editor/#{editor.id}"

  removePreviewForEditor: (editor) ->
    uri = @uriForEditor(editor)
    previewPane = atom.workspace.paneForURI(uri)
    if previewPane?
      previewPane.destroyItem(previewPane.itemForURI(uri))
      true
    else
      false

  addPreviewForEditor: (editor) ->
    uri = @uriForEditor(editor)
    previousActivePane = atom.workspace.getActivePane()
    options =
      searchAllPanes: true
    if atom.config.get('atom-rst-preview-docutils.openPreviewInSplitPane')
      options.split = 'right'
    atom.workspace.open(uri, options).then (rstPreviewView) ->
      if isRestructeredTextPreviewView(rstPreviewView)
        previousActivePane.activate()

  previewFile: ({target}) ->
    filePath = target.dataset.path
    return unless filePath

    for editor in atom.workspace.getTextEditors() when editor.getPath() is filePath
      @addPreviewForEditor(editor)
      return

    atom.workspace.open "atom-rst-preview-docutils://#{encodeURI(filePath)}", searchAllPanes: true

  copyHtml: ->
    editor = atom.workspace.getActiveTextEditor()
    return unless editor?

    renderer ?= require './renderer'
    text = editor.getSelectedText() or editor.getText()
    renderer.toHTML text, editor.getPath(), editor.getGrammar(), (error, html) ->
      if error
        console.warn('Copying RestructeredText as HTML failed', error)
      else
        atom.clipboard.write(html)
